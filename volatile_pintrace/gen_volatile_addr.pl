#!/usr/bin/perl

use strict;
use warnings;
use Cwd;

my $VERBOSE = 0;
my $KEEP_TEMPS = 1;
my $OUTPUT_FILE = "";
my $ALL_VAR_ADDRS_OUTPUT = "all_global_var_addrs.txt";
my %name_to_addr = ();
my @all_vol_addrs = ();
my @all_addrs = ();

my $UNIT_TEST_DIR = "unittest";
my $TMP_TEST_DIR = "tmp_unittest_dir";

sub print_msg($) {
  my ($msg) = @_;
  print $msg if ($VERBOSE);
}

sub runit ($) {
  my ($cmd) = @_;
  print_msg("runit: $cmd\n");
  if ((system "$cmd") != 0) {
    return -1;
  }
  my $exit_value  = $? >> 8;
  return $exit_value;
}

sub process_nm_output($) {
  my ($nm_fname) = @_;

  my @addresses = ();
  open INF, "<$nm_fname" or die "Cannot open $nm_fname!";
  while (my $line = <INF>) {
    chomp $line;
    if ($line =~ m/0*([0-9a-fA-F]+)[\s\t]+[rbBdD][\s\t](.+)$/) {
      my $addr = hex($1);
      my $name = $2;
      die "duplicate var name[$name]!" if (defined($name_to_addr{$name}));
      $name_to_addr{$name} = $addr;
      #print "add one: $name, $addr\n";
    }
  }
  close INF;
  return 0;
}

sub get_name($) {
  my ($str) = @_;

  $str =~ s/[(\s\t]//g;
  if ($str =~ m/(.+?)[\+\.]/) {
    return $1;
  }
  return $str;
}

sub get_mask_str($) {
  my ($bin_str) = @_;

  my $hex_str = sprintf("%x", oct("0b$bin_str"));
  return $hex_str;
}

sub check_remaining_bits($$$$) {
  my ($prev_full_name_ref, $prev_addr_ref, $bits_mask, $addrs_array) = @_;

  return if ($$bits_mask eq "00000000"); 

  die "bad prev_addr:$$prev_full_name_ref, $$bits_mask!" if ($$prev_addr_ref == 0);
  my $mask_str = get_mask_str($$bits_mask);
  # print "check: mask_str: $$bits_mask, str:$mask_str\n";
  my $s = sprintf "$$prev_full_name_ref; 0x%x; 1; non-pointer; $mask_str\n", $$prev_addr_ref;
  # print "check_remaining_bits: $s\n";
  push @$addrs_array, $s;
  $$prev_addr_ref = 0;
  $$prev_full_name_ref = "";
  $$bits_mask = "00000000";
}

sub set_bits($$$) {
  my ($mask, $from, $sz) = @_;
  
  return if ($sz == 0);

  my $to = $from + $sz;
  die "bad set bits: from[$from], sz[$sz]!" if ($to > 8);
  my $s = "";
  $s =~ s/^(.*)/'1' x $sz/e;
  # print "from[$from], to[$to], sz[$sz]\n";
  substr($$mask, $from, $sz, $s);
  # print "$$mask, " . get_mask_str($$mask) . "\n";
}

sub filter_names($) {
  my ($name) = @_;
  return 1 if ($name eq "__undefined");
  return 0;
}

sub process_addr_file($$$) {
  my ($addr_file, $addrs_array, $skip_pointer) = @_;

  my $next_addr = 0;
  open INF, "<$addr_file" or die "cannot open $addr_file!";
  my $prev_addr = 0;
  my $prev_offset = 0;
  my $prev_full_name = "";
  my $prev_name = "";
  my $bits_mask = "00000000";

  while (my $line = <INF>) {
    chomp $line;
    next if ($line eq "Succeeded");
    # print "handle:$line\n";
    my @a = split(';', $line);
    if (@a != 5) {
      print "Invalid line:$line\n";
      return -1;
    }
    my $name = get_name($a[0]);
    if ($prev_name ne $name) {
      $prev_addr = 0;
      $prev_offset = 0;
      $bits_mask = "00000000";
      $prev_full_name = "";
    }
    $prev_name = $name;
    next if (filter_names($name));

    my $addr = $name_to_addr{$name};
    if (!defined($addr)) {
      # print "unknown name[$name]!\n";
      # return -1;
      # it is possible that a var in the source code does not
      # appear in nm's outout, e.g. compiler can optimize out
      # an unused static global
      check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
      next;
    }
    my $bits_offset = $a[1];
    my $bits_size = $a[2];
    my $ptr_str = $a[3];
    $ptr_str =~ s/[\s\t]//g;
    if ($skip_pointer && ($ptr_str eq "pointer")) {
      check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
      next;
    }

    my $sz = 0;
    my $bitfield_str = $a[4];
    $bitfield_str =~ s/[\s\t]//g;
    if ($bitfield_str eq "non-bitfield") {
      check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
      die "bad bits_offset:$bits_offset!" unless (($bits_offset % 8) == 0);
      die "bad bits_sz:$bits_size!" unless (($bits_size % 8) == 0);
      my $f_addr = $addr + $bits_offset / 8;
      $sz = int($bits_size / 8);
      my $s = sprintf "$a[0]; 0x%x; $sz; $ptr_str\n", $f_addr;
      push @$addrs_array, $s;
      next;
    }

    # print "$curr_addr, $ptr_str, $bits_offset, $bits_size\n";
    if (($bits_offset % 8) == 0) {
      check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
      my $f_addr = $addr + ($bits_offset / 8);

      my $remaining_bits = $bits_size % 8;
      if ($remaining_bits == 0) {
        $sz = $bits_size / 8;
        my $s = sprintf "$a[0]; 0x%x; $sz; $ptr_str\n", $f_addr;
        push @$addrs_array, $s;
        $prev_offset = $bits_offset + $bits_size;
      }
      else {
        $prev_full_name = $a[0];
        $prev_addr = $addr + int(($bits_offset + $bits_size) / 8);
        set_bits(\$bits_mask, 0, $remaining_bits);
        if ($bits_size < 8) {
          next;
        }

        $sz = int($bits_size / 8);
        my $s = sprintf "$a[0]; 0x%x; $sz; $ptr_str\n", $f_addr;
        push @$addrs_array, $s;
        $prev_offset = $bits_offset + $sz * 8;
      }
    }
    else {
      if ($prev_offset == 0) {
        $prev_offset = 8 * (int($bits_offset/8));
      }
      else {
        die "bad offsets: bits_offset[$bits_offset], prev_offset[$prev_offset]" if
          ($prev_offset >= $bits_offset);
      }

      $prev_full_name = $a[0] if ($prev_full_name eq "");
      if ($prev_addr == 0) {
        $prev_addr = $addr + int($bits_offset/8);
      }

      my $rel_off = $bits_offset - $prev_offset;
      if (($rel_off + $bits_size) < 8) {
        set_bits(\$bits_mask, $rel_off, $bits_size);
        next;
      }

      # handle hole here: bitfield10.c
      if ($rel_off > 8) {
        check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
        $rel_off = $bits_offset % 8;
        $prev_offset = 8 * (int($bits_offset/8));
        die "bad bits_mask:$bits_mask" if ($bits_mask ne "00000000");
        $prev_full_name = $a[0]; 
        $prev_addr = $addr + int($bits_offset/8);
        # print "$prev_offset, $rel_off, $prev_full_name, $prev_addr\n";
      }

      die "bad rel_off:$rel_off, bits_offset[$bits_offset], prev_offset[$prev_offset]!" if ($rel_off > 8);
      # test case bitfield11.c
      if (($rel_off + $bits_size) < 8) {
        set_bits(\$bits_mask, $rel_off, $bits_size);
        # check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
        next;
      }

      set_bits(\$bits_mask, $rel_off, 8-$rel_off);
      check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);

      my $new_offset = 8 * (int($bits_offset/8)) + 8;
      my $new_bits_sz = $bits_size - ($new_offset - $bits_offset);
      $prev_offset = $new_offset;
      die "bad new_bits_sz[$new_bits_sz]: $a[0], bits_size[$bits_size], new_offset[$new_offset], bits_offset[$bits_offset]!" 
        if ($new_bits_sz < 0);
      next if ($new_bits_sz == 0);

      my $remaining_bits = $new_bits_sz % 8;
      $prev_addr = $addr + int(($new_offset + $new_bits_sz) / 8);
      $prev_offset = 8 * int(($new_offset + $new_bits_sz) / 8);

      if ($new_bits_sz < 8) {
        die "bad remaining_bits:$remaining_bits!" if ($remaining_bits == 0);
        $bits_mask = "00000000";
        set_bits(\$bits_mask, 0, $remaining_bits);
        $prev_full_name = $a[0];
        next;
      }

      my $f_addr = $addr + ($bits_offset / 8) + 1;
      if ($prev_full_name eq "") {
        $prev_full_name = $a[0];
      }
      $sz = int($new_bits_sz / 8);
      my $s = sprintf "$prev_full_name; 0x%x; $sz; $ptr_str\n", $f_addr;
      push @$addrs_array, $s;

      if (($remaining_bits % 8) != 0) {
        $bits_mask = "00000000";
        set_bits(\$bits_mask, 0, $remaining_bits);
        $prev_full_name = $a[0];
      }
      else {
        $prev_full_name = "";
      }
    }
  }
  check_remaining_bits(\$prev_full_name, \$prev_addr, \$bits_mask, $addrs_array);
  close INF;
  return 0;
}

sub dump_result($) {
  my ($all_addr_file) = @_;

  if ($OUTPUT_FILE ne "") {
    open OUT, ">$OUTPUT_FILE" or die "cannot open $OUTPUT_FILE!";
    foreach my $s (@all_vol_addrs) {
      print OUT "$s";
    }
    close OUT;
  }
  else {
    foreach my $s (@all_vol_addrs) {
      print "$s";
    }
  }

  return if ($all_addr_file eq "");
  open ALL_OUT, ">$ALL_VAR_ADDRS_OUTPUT" or die "cannot open $ALL_VAR_ADDRS_OUTPUT!";
  foreach my $v (@all_addrs) {
    print ALL_OUT "$v";
  }
  close ALL_OUT;
}

sub doit($$$$) {
  my ($addr_file, $all_addr_file, $exec, $for_unit_test) = @_;

  my $cmd;
  my $res;

  my $nm_out = "$exec.nm.out";
  $cmd = "nm $exec > $nm_out 2>&1";
  $res = runit($cmd);
  if ($res) {
    print "failed to run $cmd\n";
    goto out;
  }
  $res = process_nm_output($nm_out);
  if ($res) {
    print "failed to process nm output!\n";
    goto out;
  }
  $res = process_addr_file($addr_file, \@all_vol_addrs, 0);
  if ($res) {
    print "failed to process address file!\n";
    goto out;
  }
  if ($all_addr_file ne "") {
    $res = process_addr_file($all_addr_file, \@all_addrs, 1);
  }

  # the pintool will read crc32_context from all_addr_output,
  # then we don't need to fake it as a volatile now
=comment
  my $global_checksum = "crc32_context";
  my $global_checksum_addr = $name_to_addr{$global_checksum};
  if (defined($global_checksum_addr)) {
    my $s = sprintf "$global_checksum; 0x%x; 4; non-pointer\n", $global_checksum_addr;
    push @all_vol_addrs, $s;
  }
=cut

  dump_result($all_addr_file) if (!$for_unit_test);
out:
  return $res if ($for_unit_test);
  if (!$KEEP_TEMPS) {
    system("rm -rf $nm_out");
  }
  die if ($res);
  return 0;
}

sub unittest_one_addr_file($$$$) {
  my ($checker_out, $ref_out, $skip_pointer, $regenerate) = @_;

  @all_vol_addrs = ();
  return -1 if (process_addr_file($checker_out, \@all_vol_addrs, 0));
  if ($regenerate) {
    open OUT, ">$ref_out" or die "cannot open $ref_out";
    foreach my $s (@all_vol_addrs) {
      print OUT "$s";
    }
    close OUT;
    return 0;
  }
  
  my $i = 0;
  my $curr_name = "";
  my $curr_ref_base = 0;
  my $curr_new_base = 0;
  open INF, "<$ref_out" or die "cannot open $ref_out";
  while (my $line = <INF>) {
    chomp $line;
    my $new_str = $all_vol_addrs[$i];
    goto fail unless (defined($new_str));
    my @ref_a = split(';', $line);
    my @new_a = split(';', $new_str);
    goto fail if ((@ref_a < 4) || (@new_a < 4));
    goto fail if ((@ref_a > 5) || (@new_a > 5));
    goto fail if ($ref_a[0] ne $new_a[0]);
    goto fail if ($ref_a[2] != $new_a[2]);
    my $ref_ptr = $ref_a[3];
    my $new_ptr = $new_a[3];
    $ref_ptr =~ s/\s//g;
    $new_ptr =~ s/\s//g;
    goto fail if ($ref_ptr ne $new_ptr);

    if (@ref_a == 5) {
      my $ref_bitoff = $ref_a[4];
      my $new_bitoff = $new_a[4];
      $ref_bitoff =~ s/\s//g;
      $new_bitoff =~ s/\s//g;
      goto fail if ($ref_bitoff ne $new_bitoff);
    }

    my $ref_name = get_name($ref_a[0]);
    my $new_name = get_name($ref_a[0]);
    goto fail if ($ref_name ne $new_name);
    my $ref_addr = $ref_a[1];
    my $new_addr = $new_a[1];
    $ref_addr =~ s/^[\s]0x//;
    $new_addr =~ s/^[\s]0x//;
    $ref_addr = hex($ref_addr);
    $new_addr = $ref_addr;
    $i++;
    if ($curr_name ne $ref_name) {
      $curr_name = $ref_name;
      $curr_ref_base = $ref_addr;
      $curr_new_base = $new_addr;
      next;
    }
    else {
      # print "$ref_addr, $curr_ref_base, $new_addr, $curr_new_base\n";
      goto fail if (($ref_addr - $curr_ref_base) != ($new_addr - $curr_new_base));
    }
  }
  goto fail if ($i != @all_vol_addrs);
  close INF;
  return 0;

fail:
  close INF;
  return -1;
}

sub do_one_unit_test($$$$) {
  my ($cfile, $ref_out, $all_vars_ref_out, $regenerate) = @_;

  %name_to_addr = ();
  my $checker_all_vars_out = "checker.all_vars.out";
  my $checker = "../../volatile_checker/volatile_checker --checker=volatile-address --all-vars-output=$checker_all_vars_out";
  my $checker_out = "checker.out";
  my $exec = "tmp_test.out";
  my $cmd;
  $cmd = "$checker $cfile > $checker_out 2>&1";
  return -1 if (runit($cmd));
  $cmd = "gcc $cfile -o tmp_test.out";
  return -1 if (runit($cmd));

  my $nm_out = "$exec.nm.out";
  $cmd = "nm $exec > $nm_out 2>&1";
  return -1 if (runit($cmd));
  return -1 if (process_nm_output($nm_out));
  return -1 if (unittest_one_addr_file($checker_out, $ref_out, 0, $regenerate));
  return unittest_one_addr_file($checker_all_vars_out, $all_vars_ref_out, 1, $regenerate);
}

sub do_unit_test($) {
  my ($regenerate) = @_;
  
  my $msg;
  if ($regenerate) {
    $msg = "Start regenerating ref output for each unittest...";
  }
  else {
    $msg = "Start unit-testing...";
  }
  print "$msg\n";
  if (-d $TMP_TEST_DIR) {
    system("rm -rf $TMP_TEST_DIR/*");
  }
  else {
    mkdir $TMP_TEST_DIR or die;
  }

  my $cwd = cwd();
  $UNIT_TEST_DIR = "$cwd/$UNIT_TEST_DIR";
  chdir $TMP_TEST_DIR or die;
  my @all_tests = glob("$UNIT_TEST_DIR/*.c");
  foreach my $test (@all_tests) {
    my $ref_out = $test;
    $ref_out =~ s/\.c/\.out/;
    my $all_vars_ref_out = $test;
    $all_vars_ref_out =~ s/\.c/\.all_vars\.out/;
    print "  [$test]...";
    if (do_one_unit_test($test, $ref_out, $all_vars_ref_out, $regenerate)) {
      die "FAILED!\n";
    }
    else {
      print "SUCCEEDED!\n";
    }
  }
}

###################################################

my $help_msg = '
gen_volatile_addr.pl --vars-file=<file> [--all-vars-file=<file>] exec
  where:
  exec: executable
  --vars-file=<file>: volatile vars file generated by volatile_checker
  --all-vars-file=<file>: all vars (including both volatiles and non-volatiles) file generated by volatile_checker
  --all-var-addrs-output=<file>: where to dump the actual addresses of all global vars [default: all_global_var_addrs.txt]
  --not-keep-temps: do not keep the temp files
  --verbose: print verbose message
  --output=<file>: where to dump the generated result [default: stdout]
  --test: do unit-testing using the existing test cases
  --regenerate-test-output: regenerate output of unittest
  --help: this message
';

sub die_on_invalid_opt($) {
  print "Invalid opt: $1\n";
  print("$help_msg\n");
  die;
}

sub main() {
  my $opt;
  my @unused = ();
  my $addr_file;
  my $all_addr_file = "";
  my $test = 0;
  my $regenerate = 0;

  while(defined($opt = shift @ARGV)) {
    if ($opt =~ m/^--(.+)=(.+)$/) {
      if ($1 eq "output") {
        $OUTPUT_FILE = $2;
      }
      elsif ($1 eq "vars-file") {
        $addr_file = $2;
      }
      elsif ($1 eq "all-vars-file") {
        $all_addr_file = $2;
      }
      elsif ($1 eq "all-var-addrs-output") {
        $ALL_VAR_ADDRS_OUTPUT = $2;
      }
      else {
        die_on_invalid_opt($opt); 
      }
    }
    elsif ($opt =~ m/^--(.+)$/) {
      if ($1 eq "verbose") {
        $VERBOSE = 1;
      }
      elsif ($1 eq "not-keep-temps") {
        $KEEP_TEMPS = 0;
      }
      elsif ($1 eq "help") {
        print "$help_msg\n";
        exit 0;
      }
      elsif ($1 eq "test") {
        $test = 1;
      }
      elsif ($1 eq "regenerate-test-output") {
        $regenerate = 1;
      }
      else {
        die_on_invalid_opt($opt); 
      }
    }
    else {
      push @unused, $opt
    }
  }
   
  if ($test) {
    do_unit_test($regenerate);
    return;
  }

  if (@unused == 0) {
    print("please give an input exec file");
    print "$help_msg\n";
    die;
  }
  elsif (@unused > 1) {
    die_on_invalid_opt("Multiple inputs!");
  }

  doit($addr_file, $all_addr_file, $unused[0], 0);
}

main();

