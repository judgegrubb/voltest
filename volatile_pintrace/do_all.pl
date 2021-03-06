#!/usr/bin/perl -w

use strict;
use warnings;

#my $GCC = "/scratch/chenyang/compilers/compiler-install/gcc-481/bin/gcc";
#my $GCC = "/scratch/chenyang/compilers/compiler-install/llvm-r191259-install/bin/clang";
#my $GCC = "/scratch/chenyang/compilers/compiler-install/gcc-r202631-install/bin/gcc";
my $GCC = "/scratch/chenyang/compilers/compiler-install/compcert-2.0/bin/ccomp";
#my $OPT = "-O3 -Werror=uninitialized -fno-zero-initialized-in-bss -g -gdwarf-2";
#my $OPT = "-O2";
my $SCRATCH = "/scratch/chenyang";
my $CSMITH_HOME = "$SCRATCH/csmith";
my $PIN_HOME = "$SCRATCH/programs/pin-2.12-55942-gcc.4.4.7-linux";
my $CHECKER = "$SCRATCH/voltest/volatile_checker/volatile_checker";
my $GEN_VOLATILE_ADDR = "$SCRATCH/voltest/volatile_pintrace/gen_volatile_addr.pl";
#my $TARGET = "obj-intel64";
my $TARGET = "obj-ia32";
my $PIN_BIN = "$PIN_HOME/pin.sh -injection child -t $PIN_HOME/source/tools/ManualExamples/$TARGET/pinatrace.so";
#my $PIN_RANDOM_READ = "-random_read";
my $PIN_RANDOM_READ = "";

sub runit ($) {
  my ($cmd) = @_;
  print "runit: $cmd\n";
  if ((system "$cmd") != 0) {
    return -1;
  }
  my $exit_value  = $? >> 8;
  return $exit_value;
}

sub abort_if_fail($) {
  my ($cmd) = @_;
  die "Fatal error!" if (runit($cmd));
}

die "Usage: do_all.pl <pin-mode> <cfile> <opt>" unless (@ARGV == 3);

my $mode = $ARGV[0];
my $cfile = $ARGV[1];
my $OPT = "-$ARGV[2]";
my $CHECKER_OPT = "";
my $ARCH_OPT = "";
if ($TARGET =~ m/ia32/) {
  $OPT .= " -m32";
  $CHECKER_OPT = "--m32";
  $ARCH_OPT = "-m32";
}

if ($GCC =~ m/compcert/) {
  $OPT = "-fall";
  $ARCH_OPT = "";
}

# summary, checksum, verbose
my $PIN_OUTPUT_MODE = "-output_mode $mode";
my $base = $cfile;
$base =~ s/.c$//;
my $preprocessed_cfile = "$base.pre.c";
my $gcc_compile_output = "$base.gcc.compile.out";
my $clang_addr_file = "$base.clang.addr";
my $clang_all_addr_file = "$base.clang.all.addr";
my $addr_file = "$base.addr";
my $all_addr_file = "$base.all.addr";
my $exe_file = "$base.out";
my $pin_out = "$base.pin.out";

abort_if_fail("$GCC -I$CSMITH_HOME/runtime $ARCH_OPT -E $cfile > $preprocessed_cfile");
abort_if_fail("$CHECKER $CHECKER_OPT --checker=volatile-address --all-vars-output=$clang_all_addr_file > $clang_addr_file $preprocessed_cfile 2>&1");
abort_if_fail("$GCC $OPT $preprocessed_cfile -o $exe_file > $gcc_compile_output 2>&1");
abort_if_fail("$GEN_VOLATILE_ADDR --vars-file=$clang_addr_file --all-vars-file=$clang_all_addr_file --all-var-addrs-output=$all_addr_file $exe_file > $addr_file 2>&1");
if ($mode eq "checksum") {
  abort_if_fail("$PIN_BIN -vol_input $addr_file $PIN_OUTPUT_MODE $PIN_RANDOM_READ -- ./$exe_file  2>&1");
}
else {
  abort_if_fail("$PIN_BIN -vol_input $addr_file $PIN_OUTPUT_MODE $PIN_RANDOM_READ -- ./$exe_file > $pin_out 2>&1");
}

