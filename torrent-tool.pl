#!/usr/bin/perl
use strict;
use Data::Dumper;
use Getopt::Long;
use Digest::SHA1 qw(sha1_hex);
use constant SHASIZE => 20;

$Data::Dumper::Useqq = 1;

my $VERSION = 0.1;
my $opts    = {};
GetOptions($opts, "help|h", "version", "dump", "show", "verify", "path=s");
my $infile = $ARGV[0];

if($opts->{version}) {
	die "torrent-tool $VERSION\n";
}
elsif($opts->{help}) {
	die << "EOF"
$0 [--version] [--help] [--dump --show --verify TORRENT_FILE]

    --version    : Display version information
    --help       : Display this text
    --dump       : Dump raw torrent information
    --show       : Display human readable information (default)
    --verify     : Verify given torrent, use --path to specify a 
                   searchpath (default is: current working directory)

EOF
}
elsif(!$infile or !-f $infile) {
	die "Usage: $0 COMMAND INPUT_FILE\n   (run: '$0 --help' for more information)\n\n";
}
elsif($opts->{verify}) {
	$| = 1;
	verify_torrent($infile, $opts->{path});
}
elsif($opts->{dump}) {
	dump_torrent($infile);
}
else { # --show is the default
	info_torrent($infile);
}


sub verify_torrent {
	my($filename, $basepath) = @_;
	
	my $ref   = _slurp($filename);
	my $plen  = $ref->{info}->{'piece length'};
	my $sha   = $ref->{info}->{pieces};
	my $files = [];
	
	if(ref($ref->{info}->{files}) eq 'ARRAY') {
		foreach my $fref (@{$ref->{info}->{files}}) {
			push(@$files, {path=>join("/", @{$fref->{path}}), length=>$fref->{length}});
		}
	}
	else {
		push(@$files, {path=>$ref->{info}->{name}, length=>$ref->{info}->{length}});
	}
	
	
	my $file_index = 0;
	my $this_path  = undef;
	my $cnt_good   = 0;
	my $cnt_bad    = 0;
	my $badfiles   = {};
	
	for(my $i=0; $i<length($sha); $i+=SHASIZE) {
		my $this_sha   = substr($sha,$i,SHASIZE);
		my $this_piece = $i / SHASIZE;
		my $need_bytes = $plen;
		my $pbuffer    = '';
		
		while($need_bytes > 0) {
			my $src_ref = $files->[$file_index] or last; # got all pieces
			if($src_ref->{path} ne $this_path) { # new file -> must update FH
				close(FH);
				$this_path  = $src_ref->{path};
				my $vfs     = join("/",$basepath, $this_path);
				open(FH, "<", join("/",$vfs)) or die "Could not open: $vfs\n";
			}
			my $buff        = '';
			my $got_bytes   = sysread(FH,$buff,$need_bytes);
			   $pbuffer    .= $buff;
			   $need_bytes -= $got_bytes;
			$file_index++ if $got_bytes < 1;
		}
		
		if( unpack("H*",$this_sha) eq sha1_hex($pbuffer) ) {
			$cnt_good++;
		}
		else {
			$cnt_bad++;
			$badfiles->{$this_path}++;
		}
		
		print "\rpiece=$this_piece, ok=$cnt_good, bad=$cnt_bad" if $this_piece % 4 == 0;
	}
	
	print "\r".(" " x 32 );
	print "\rfound $cnt_bad bad piece(s)\n";
	foreach my $this_bad (keys(%$badfiles)) {
		printf("%-64s : %d bad bytes (%d pieces)\n", $this_bad, $badfiles->{$this_bad}*$plen, $badfiles->{$this_bad});
	}
	
	
}


################################################################################################
# Display human readable information about the input file
sub info_torrent {
	my($filename) = @_;
	
	my $ref     = _slurp($filename);
	my $pstring = delete($ref->{info}->{pieces});
	
	my $num_pieces = ( length($pstring) / SHASIZE ); # SHASIZE = length of sha1
	my $size_piece = $ref->{info}->{'piece length'};
	my $total_size = $ref->{info}->{length};
	my $waste      = 0;
	my $files      = 0;
	
	if($total_size == 0 && ref($ref->{info}->{files}) eq 'ARRAY') {
		foreach my $fref (@{$ref->{info}->{files}}) {
			$total_size += $fref->{length};
			$files++;
		}
	}
	else {
		$files = 1; # singlefile torrent
	}
	
	$waste = $size_piece * $num_pieces - $total_size;
	
	
	printf("Torrent file     : %s\n", $filename);
	printf("Internal name    : %s\n", $ref->{info}->{name});
	printf("Size information : %d pieces * %d bytes per piece = %d bytes (%d bytes wasted)\n", $num_pieces, $size_piece, $total_size, $waste);
	printf("Number of files  : %d\n", $files);
	printf("Created at       : %s (GMT)\n", "".gmtime($ref->{'creation date'}));
}


################################################################################################
# Dump torrent via Data::Dumper - removes binary junk (info->pieces)
sub dump_torrent {
	my($filename) = @_;
	
	my $ref    = _slurp($filename);
	my $pieces = delete($ref->{info}->{pieces});
	print Data::Dumper::Dumper($ref);
}


sub _slurp {
	my($filename) = @_;
	open(TORRENT,"< ", $filename) or die "Could not open: $filename: $!\n";
	my $buff = join("", <TORRENT>);
	close(TORRENT);
	return TorrentTool::Bencoder::decode($buff);
}




################################################################################################
# Bencoder lib
package TorrentTool::Bencoder;
	
	sub decode {
		my($string) = @_;
		my $ref = { data=>$string, len=>length($string), pos=> 0 };
		Carp::confess("decode(undef) called") if $ref->{len} == 0;
		return undef if $string !~ /^[dli]/;
		return d2($ref);
	}
	
	sub encode {
		my($ref) = @_;
		Carp::confess("encode(undef) called") unless $ref;
		return _encode($ref);
	}
	
	
	
	sub _encode {
		my($ref) = @_;
		
		Carp::cluck() unless defined $ref;
		
		my $encoded = undef;
		my $reftype = ref($ref);
		
		if($reftype eq "HASH") {
			$encoded .= "d";
			foreach(sort keys(%$ref)) {
				$encoded .= length($_).":".$_;
				$encoded .= _encode($ref->{$_});
			}
			$encoded .= "e";
		}
		elsif($reftype eq "ARRAY") {
			$encoded .= "l";
			foreach(@$ref) {
				$encoded .= _encode($_);
			}
			$encoded .= "e";
		}
		elsif($ref =~ /^-?\d+$/) {
			$encoded .= "i".int($ref)."e";
		}
		else {
			# -> String
			$ref      = ${$ref} if $reftype eq "SCALAR"; # FORCED string
			$encoded .= length($ref).":".$ref;
		}
		return $encoded;
	}
	

	sub d2 {
		my($ref) = @_;
		
		my $cc = _curchar($ref);
		
		if(!defined($cc)) {
			# do nothing -> hit's ABORT_DT
		}
		elsif($cc eq 'd') {
			my $dict = {};
			for($ref->{pos}++;$ref->{pos} < $ref->{len};) {
				last if _curchar($ref) eq 'e';
				my $k = d2($ref);
				my $v = d2($ref);
				goto ABRT_DT unless defined $k; # whoops -> broken bencoding
				$dict->{$k} = $v;
			}
			$ref->{pos}++; # Skip the 'e'
			return $dict;
		}
		elsif($cc eq 'l') {
			my @list = ();
			for($ref->{pos}++;$ref->{pos} < $ref->{len};) {
				last if _curchar($ref) eq 'e';
				push(@list,d2($ref));
			}
			$ref->{pos}++; # Skip 'e'
			return \@list;
		}
		elsif($cc eq 'i') {
			my $integer = '';
			for($ref->{pos}++;$ref->{pos} < $ref->{len};$ref->{pos}++) {
				last if _curchar($ref) eq 'e';
				$integer .= _curchar($ref);
			}
			$ref->{pos}++; # Skip 'e'
			return int($integer);
		}
		elsif($cc =~ /^\d$/) {
			my $s_len = '';
			while($ref->{pos} < $ref->{len}) {
				last if _curchar($ref) eq ':';
				$s_len .= _curchar($ref);
				$ref->{pos}++;
			}
			$ref->{pos}++; # Skip ':'
			
			return ''    if !$s_len;
			goto ABRT_DT if ($s_len !~ /^\d+$/ or $ref->{len}-$ref->{pos} < $s_len);
			my $str = substr($ref->{data}, $ref->{pos}, $s_len);
			$ref->{pos} += $s_len;
			return $str;
		}
		
		ABRT_DT:
			$ref->{pos} = $ref->{len};
			return undef;
	}

	sub _curchar {
		my($ref) = @_;
		return(substr($ref->{data},$ref->{pos},1));
	}
1;
