#
# GPL HEADER START
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 only,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License version 2 for more details (a copy is included
# in the LICENSE file that accompanied this code).
#
# You should have received a copy of the GNU General Public License
# version 2 along with this program; If not, see http://www.gnu.org/licenses
#
# Please  visit http://www.xyratex.com/contact if you need additional
# information or have any questions.
#
# GPL HEADER END
#
# Copyright 2012 Xyratex Technology Limited
#
# Author: Roman Grigoryev<Roman_Grigoryev@xyratex.com>
#

=pod

=head1 NAME

Xperior::Test - Class implements Test abstraction.


=head1 DESCRIPTION

The class is used for describing tests and keep passive information
for executors. Executor class use Test for get all information about
test under execution.

=cut

package Xperior::Test;
use Moose;
use Data::Dumper;

use Log::Log4perl qw(:easy);

our $VERSION = '0.02';

with qw(MooseX::Clone);


has 'testcfg'  => ( is => 'rw' ,traits => [qw(Clone)]);
has 'groupcfg' => ( is => 'rw' ,traits => [qw(Clone)]);
has 'tap'      => ( is => 'rw' ,traits => [qw(Clone)]);
has 'results'  => ( is => 'rw' ,traits => [qw(Clone)]);
has 'excluded' => ( is => 'rw' ,traits => [qw(Clone)]);
has 'skipped'  => ( is => 'rw' ,traits => [qw(Clone)]);
has 'weight'   => ( is => 'rw' ,traits => [qw(Clone)], default => 50);

sub init {
    my $self = shift;
    $self->{'testcfg'}  = shift;
    $self->{'testcfg'}->{'testname'} = $self->{'testcfg'}->{'id'};
    $self->{'groupcfg'} = shift;
    if($self->{'testcfg'}->{'weight'}){
        $self->weight($self->{'testcfg'}->{'weight'});
    }else{
        $self->{'testcfg'}->{'weight'} = $self->weight();
    }
}

=head getId

Returns name of a test. Name could be defined as I<name> in test descriptor.
Test id is returned if I<name> is not defined.

=back

=cut

sub getId {
    my $self = shift;
    return $self->testcfg->{'id'};
}

=head getTestName

Returns name of a test. Name could be defined as I<name> in test descriptor.
Test id is returned if I<name> is not defined.

=back

=cut

sub getTestName {
    my $self = shift;
    return $self->testcfg->{'testname'}
        if ( defined( $self->testcfg->{'testname'} ) );
    ERROR 'No testname defined!';
    return '';
}

=head2 getParamNames

Return list of available parameters for test (from test description and group
description considering inheritance).

=back

=cut

sub getParamNames {
    my $self = shift;
    my @names;
    foreach my $n ( keys %{ $self->testcfg } ) {
        push @names, $n;
    }
    foreach my $n ( keys %{ $self->groupcfg } ) {
        push @names, $n;
    }

    #print Dumper \@names;
    return \@names;
}



=head2 getParam

Returns parameter value by given L<name>. If L<compare> argument is defined,
returns result of comparison of its value and parameter.

=back

=cut

sub getParam {
    my ( $self, $name, $compare ) = @_;

    my $value;

    if ( defined( $self->testcfg->{$name} ) ) {
        $value = $self->testcfg->{$name};
    }
    elsif ( defined( $self->groupcfg->{$name} ) ) {
        $value = $self->groupcfg->{$name};
    }

    if ( defined($compare) ) {
        $value = defined($value) ? $value eq $compare : 0;
    }

    return $value;
}

=head2 getSubTestParam

Returns parameter value by given L<name> and L<subtest_name>.
If L<compare> argument is defined,
returns result of comparison of its value and parameter.

=back

=cut

sub getSubTestParam {
    my ( $self, $subtestname, $name, $compare ) = @_;

    my $value;
    if ( defined( $self->testcfg->{'subtests'}->{$subtestname}->{$name} )) {
        $value = $self->testcfg->{'subtests'}->{$subtestname}->{$name};
    }elsif ( defined( $self->testcfg->{$name} ) ) {
        $value = $self->testcfg->{$name};
    }elsif ( defined( $self->groupcfg->{$name} ) ) {
        $value = $self->groupcfg->{$name};
    }

    if ( defined($compare) ) {
        $value = defined($value) ? $value eq $compare : 0;
    }

    return $value;
}



=head2 getMergedHashParam($name)

Returns merged hash for parameter L<name>.
L<Name> should be hash and could be different on
group or/and test level.

Result is hash which merged by rules:

- uniq items from group and test hashes are added to results
- test level items override group level items when key is same

Examples
for B<testds>

 - id: 99
   env:
      mdtest_THREADS: 50
      mdtest_iteration: 10
   env:
    mdtest_THREADS: 8
	mdtest_iteration: 10

result hash env for test 99 will be
  mdtest_THREADS   => 50
  mdtest_iteration => 10


=back

=cut

sub getMergedHashParam {
    my ( $self, $name ) = @_;

    my %test;
    my %grp;

    if ( defined( $self->testcfg->{$name} ) ) {
        %test = %{$self->testcfg->{$name}};
    }

    if ( defined( $self->groupcfg->{$name} ) ) {
        %grp = %{$self->groupcfg->{$name}};
    }
    my %merged = ();
    while (my ($k, $v) = each %grp) {
        $merged{$k} = $v;
    }
    while (my ($k, $v) = each %test) {
        $merged{$k} = $v;
    }
    return \%merged;
}

=head2 getTags

Returns tags list for test. Tags list contains tags defined in test descriptor
and also test group name.

=back

=cut

sub getTags {
    my $self = shift;
    my @tags;
    my $ts = $self->getParam('tags');
    if ( defined($ts) ) {
        foreach my $t ( split( /\s/, $ts ) ) {
            push @tags, $t;
        }
    }
    push @tags, $self->getParam('groupname');
    return \@tags;
}

sub getGroupName {
    my $self = shift;
    return $self->getParam('groupname');
}

=head2  getDescription

Returns text description for test

=back

=cut

sub getDescription {
    my $self = shift;
    my $td   = 'none';
    if ( defined( $self->testcfg->{'description'} ) ) {
        $td = $self->testcfg->{'description'};
    }
    my $testname = $self->getParam('testname');
    $testname = 'not set' unless defined $testname;
    return
        "Test full name    : ["
      . $self->getParam('groupname') . "/"
      . $self->getId() . "]\n"
      . "Group description : "
      . $self->groupcfg->{'description'} . "\n"
      . "Test description  : "
      . $td . "\n"
      . "Test group        : "
      . $self->getParam('groupname') . "\n"
      . "Test Id           : ". $self->getId() . "\n"
      . "Test name         : ". $self->getTestName() . "\n"
      . "Test testname     : ". $testname. "\n"
      . "Test tags         : "
      . join( ',', @{ $self->getTags } ) . "\n";
}

sub clean {

}

=head2 _multiplyTests

Returns test array based on current test.
Option 'multirun' defines number of test in returned array. In
generated tests will be added fields 'testname', 'copy_id'
and 'numberofcopies'.

If parameter 'multirun' set to '0' or undefined then test option
'multirun' is used. If test option 'multirun' is not set also then test
will not change.

If parameter 'multirun' set to '1' then only fields 'copy_id' and
'numberofcopies' will be added to test.

=cut

sub multiply {
    my ( $self, $multiply ) = @_;
    my $count = $self->getParam('multirun');
    my @newtests;
    $count = $multiply if $multiply;
    if ( $count && $count == 1 ) {
        $self->{'testcfg'}->{'copy_id'} = 1;
        $self->{'testcfg'}->{'numberofcopies'} =1;
        push( @newtests, $self );
    }
    elsif($count){
        for ( my $i = 0 ; $i < $count ; $i++ ) {
            my $test = $self->clone();
            $test->{'testcfg'}->{'id'} = $self->{'testcfg'}->{'id'} . "__$i";
            $test->{'testcfg'}->{'testname'} = $self->{'testcfg'}->{'id'};
            $test->{'testcfg'}->{'copy_id'} = $i;
            $test->{'testcfg'}->{'numberofcopies'} = $count;
            push( @newtests, $test );
        }
    }
    else {
        push( @newtests, $self );
    }
    return @newtests;
}

__PACKAGE__->meta->make_immutable;

1;

=head1 COPYRIGHT AND LICENSE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License version 2 only,
as published by the Free Software Foundation.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
General Public License version 2 for more details (a copy is included
in the LICENSE file that accompanied this code).

You should have received a copy of the GNU General Public License
version 2 along with this program; If not, see http://www.gnu.org/licenses



Copyright 2012 Xyratex Technology Limited

=head1 AUTHOR

Roman Grigoryev<Roman_Grigoryev@xyratex.com>

=cut

