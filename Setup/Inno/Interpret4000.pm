#!/usr/bin/perl

package Setup::Inno::Interpret4000;

use strict;
require 5.006_000;
use base qw(Setup::Inno::Interpret2008);
use Switch 'Perl6';
use Carp;
use Fcntl;
use IO::File;
use IO::Uncompress::AnyInflate;
use IO::Uncompress::Bunzip2;
use File::Basename;
use Setup::Inno::LzmaReader;
use Data::Hexdumper;
use Data::Dumper;
use Digest;

use constant {
	ZLIBID => "zlb\x{1a}",
	DISKSLICEID => "idska32\x{1a}",
};

sub CheckFile {
	my ($self, $data, $location) = @_;
	print Dumper($location);
	if (defined($location->{Checksum})) {
		my $digest = Digest->new('CRC-32');
		$digest->add($data);
		# CRC-32 produces a numeric result
		return $digest->digest() == $location->{Checksum};
	}
	return 1;
}

sub SetupBinaries {
	my ($self, $reader, $compression) = @_;
	my $ret = { };
	my $wzimglength = $reader->ReadLongWord();
	$ret->{WizardImage} = $reader->ReadByteArray($wzimglength);
	my $wzsimglength = $reader->ReadLongWord();
	$ret->{WizardSmallImage} = $reader->ReadByteArray($wzsimglength);
	if ($compression && $compression !~ /LZMA/i) {
		my $cmpimglength = $reader->ReadLongWord();
		$ret->{CompressImage} = $reader->ReadByteArray($cmpimglength);
	}
	return $ret;
}

# Disk slice handling was new in 4.0.x, the exact version is unknown, but we support it from 4.0.0
sub DiskInfo {
	my ($self, $setup, $header) = @_;
	my $basedir = dirname($setup);
	opendir(my $dir, $basedir);
	my $basename = $setup;
	$basename =~ s/^.*\/(.+)\.exe$/$1/g;
	my @unsorted = grep(/^$basename-[0-9]+\.bin$/, readdir($dir));
	closedir($dir);
	my @bins = map({ $basedir . '/' . $_ } sort({ $a =~ /-([0-9]+)\.bin$/; my $first = $1; $b =~ /-([0-9]+)\.bin$/; my $second = $1; $first cmp $second; } @unsorted));
	#print Dumper(@bins);
	my @ret = ();
	my $start = 0;
	my $disk = 0;
	for my $bin (@bins) {
		my $input = IO::File->new($bin, 'r') || croak("Can't open $bin: $!");
		my $sliceoffset = 0;
		my $dataoffset = 0;
		for my $slice (0..($header->{SlicesPerDisk} - 1)) {
			$input->read(my $buffer, 12);
			my ($sliceid, $size) = unpack('a8L<', $buffer);
			$dataoffset += 12;
			if ($sliceid eq DISKSLICEID) {
				my $record = {
					Input => $input,
					File => $bin,
					Disk => $disk,
					Start => $start,
					Size => $size,
					SliceOffset => $sliceoffset,
					DataOffset => $dataoffset,
				};
				push(@ret, $record);
				$start += $size;
				$dataoffset += $size;
				$sliceoffset += $dataoffset;
				$input->seek($size, Fcntl::SEEK_CUR);
			} else {
				carp("$bin has an invalid disk slice header");
			}
		}
		$disk++;
	}
	#print Dumper(@ret);
	return \@ret;
}

# IS 4.0.0 might still be using 2.0.8 semantics, needs verification
sub ReadFile {
	my ($self, $input, $header, $location, $offset1, $password, @slices) = @_;

	#print Dumper \@slices;
	#print Dumper $header;
	#print Dumper $location;
	#print("Offset1=$offset1 StartOffset=$location->{StartOffset}\n");
	#$input->seek($offset1 + $location->{StartOffset}, Fcntl::SEEK_SET);
	#$input->read(my $dump, $location->{ChunkCompressedSize}) || croak("Can't read compressed data");
	#open(my $temp, '>', "/tmp/data.lzma2");
	#print($temp $dump);
	#undef($temp);

	# Note: once we support decryption, make sure the password is interpreted as UTF-16LE (why?)
	if ($location->{Flags}->{ChunkEncrypted} || $location->{Flags}->{foChunkEncrypted}) {
		!defined($password) && croak("File is encrypted, but no password was given");
		croak("Encryption is not supported yet");
	}

	my $buffer;

	if (@slices > 1) {
		my $i = 0;
		my $size = $location->{ChunkCompressedSize} + 4;
		my $offset = $offset1 + $location->{StartOffset} - $slices[$i]->{SliceOffset};
		my $available = $slices[$i]->{Size} - $offset;
		my $slicesize = $available < $size ? $available : $size;
		#printf("slice=$i size=$size offset=$offset available=$available slicesize=$slicesize\n");
		$slices[$i]->{Input}->seek($offset, Fcntl::SEEK_SET);
		$slices[$i]->{Input}->read($buffer, $slicesize);
		#print hexdump(data => $buffer, end_position => 127);
		my $slicedata = $buffer;
		$size -= $slicesize;
		$i++;
		while ($i < @slices && $size > 0) {
			$offset = $slices[$i]->{DataOffset};
			$available = $slices[$i]->{Size};
			$slicesize = $available < $size ? $available : $size;
			#printf("slice=$i size=$size offset=$offset available=$available slicesize=$slicesize\n");
			$slices[$i]->{Input}->seek($offset, Fcntl::SEEK_SET);
			$slices[$i]->{Input}->read($buffer, $slicesize);
			#print hexdump(data => $buffer, end_position => 127);
			$slicedata .= $buffer;
			$size -= $slicesize;
			$i++;
		}
		#print hexdump(data => $slicedata, end_position => 127);
		# Replace input handle with virtual handle over concatenated data
		# This requires Perl 5.6 or later, use IO::String or IO::Scalar for earlier versions
		$input = IO::File->new(\$slicedata, 'r') || croak("Can't create file handle for preprocessed data: $!");
	} else {
		$input->seek($offset1 + $location->{StartOffset}, Fcntl::SEEK_SET);
	}

	$input->read($buffer, 4) || croak("Can't read compressed block magic: $!");
	($buffer eq ZLIBID) || croak("Compressed block ID invalid");

	my $reader;
	if ($location->{Flags}->{ChunkCompressed} || $location->{Flags}->{foChunkCompressed}) {
		given ($self->Compression1($header)) {
			when (/Zip$/i) {
				$reader = IO::Uncompress::AnyInflate->new($input, Transparent => 0) || croak("Can't create zlib reader: $!");
			}
			when (/Bzip$/i) {
				$reader = IO::Uncompress::Bunzip2->new($input, Transparent => 0) || croak("Can't create bzip2 reader: $!");
			}
			when (/Lzma$/i) {
				$reader = Setup::Inno::LzmaReader->new($input, $location->{ChunkCompressedSize}) || croak("Can't create lzma reader: $!");
			}
			when (/Lzma2$/i) {
				$reader = Setup::Inno::Lzma2Reader->new($input, $location->{ChunkCompressedSize}) || croak("Can't create lzma2 reader: $!");
			}
			default {
				# Plain reader for stored mode
				$reader = $input;
			}
		}
	} else {
		$reader = $input;
	}

	#printf("Seeking to 0x%08x...\n", $location->{ChunkSuboffset});
	$reader->seek($location->{ChunkSuboffset}, Fcntl::SEEK_CUR);
	#print("Reading $location->{OriginalSize} bytes...\n");
	($reader->read($buffer, $location->{OriginalSize}) >= $location->{OriginalSize}) || croak("Can't uncompress file: $!");

	if ($location->{Flags}->{CallInstructionOptimized} || $location->{Flags}->{foCallInstructionOptimized}) {
		#print("Transforming binary file...\n");
		# We could just transform the whole data, but this will expose a flaw in the original algorithm:
		# It doesn't detect jump instructions across block boundaries.
		# This means we need to process block by block like the original.
		# The block size is 64KB here.
		for (my $offset = 0; $offset < length($buffer); $offset += 0x10000) {
			substr($buffer, $offset, 0x10000) = $self->TransformCallInstructions(substr($buffer, $offset, 0x10000), $offset);
		}
	}

	#print hexdump($buffer);

	#print("Verifying checksum...\n");
	($self->CheckFile($buffer, $location)) || croak("Invalid file checksum");

	return $buffer;
}

1;

