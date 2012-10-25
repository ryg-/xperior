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

Xperior::Executor::SingleProcessBase - 
    base module for control remote execution 

=head1 DESCRIPTION

This is base module for control remote execution of single process. Reused
 in several other modules which override functions. 
Inherited fom L<Xperior::Executor::Base>

=head1 METHODS

=cut



package Xperior::Executor::SingleProcessBase;
use Moose;
use Data::Dumper;
use File::Path;
use Log::Log4perl qw(:easy);
use File::Copy;

use Xperior::SshProcess;
extends 'Xperior::Executor::Base';

=head3  execute

Function execute process on remote client and control remote execution via ssh. Only one process could be executed by one object instance. Process is executed  on first found client which marked as master.

Command line for executing  should be prepared in inheritor by defining B<_prepareCommands> function.

Before execution directory 'tempdir' from system configuration will be cleaned up.

Process executing via asynchronous call from L<Xperior::SshProcess> and use its object for regular monitoring remote process status.

When remote process not found observation stopped and execution status calculated. Status calculated by results from B<processLogs>  function, 'killed' and connection issue status, worse status selected. Also it stderr and stdout saving as test logs.

=cut

sub execute{
    my $self = shift;
    my $mcl = $self->_getMasterClient;

    #saving env data
    $self->addYE('masterclient',$mcl);
    DEBUG "MC:". Dumper $mcl;
    $self->_prepareCommands;
    $self->_addCmdLogFiles;
    $self->addYE('cmd',$self->cmd);

    #$self->_saveStageInfoBeforeTest;

    #get remote processor
    my $mclo =
        $self->env->getNodeById($mcl->{'node'});
    my $testp = $mclo->getRemoteConnector;
    unless( defined( $testp)) {
        INFO 'Master client is:'.Dumper $mclo;
        confess "SSH to master client is undef";
    }
    ## create temprory dir
    my $td = '';
    $td = $self->env->cfg->{'tempdir'}
                if defined $self->env->cfg->{'tempdir'} ;
    $testp->createSync
        ('mkdir -p '.$self->env->cfg->{'client_mount_point'}.$td);
    #TODO add exit value check there. Now it doesn't have value.

#TODO check these values on empty or undefined values.
#$self->env->cfg->{'client_mount_point'}
#$self->env->cfg->{'tempdir'})

    my $starttime=time;
    $self->addYE('starttime',$starttime);

    my $cr = $testp->create($self->appname,$self->cmd);
    if($cr < 0){
        $self->fail('Cannot start remote test process on master client');
        $self->addMessage(
           'Cannot start remote process, network or remote host problem.');
        $self->test->results ($self->yaml);
        return;
    }
    #all alredy started there
    my $endtime= $starttime
        + $self->test->getParam('timeout');

    while( $endtime > time ){
        #monitoring timeout
        sleep 5;
        unless ( $testp->isAlive == 0 ) {
            INFO "Remote app is not alive, exiting";
            last;
        };

        DEBUG "Test alive, next wait cycle";
    }
    $testp->createSync('sync',30);
    $self->addYE('endtime',time);
    $self->addYE('endtime_planned',$endtime);
    ### post processing and cleanup
    my $killed=0;
    my $kt=0;
    if($testp->isAlive == 0){
        WARN "Test is alive after end of test execution, kill it";
        my $ts = $mclo->getExclusiveRC;
        DEBUG $ts->createSync('ps afx');
        DEBUG "Owned pid is:".$testp->pid;
         $testp->kill;
         $killed=1;
         $kt=$testp->killed;
    }


    $self->addYE('completed','yes');

    #$self->_saveStageInfoAfterTest;

    #cleanup tempdir after execution
    $testp->createSync
        ('rm -rf '.$self->env->cfg->{'client_mount_point'}
            .$td."/*");

    ### get logs

    my $res = $testp->getFile( $self->remote_err,
            $self->getNormalizedLogName('stderr'));
    if($res == 0){
        $self->registerLogFile('stderr',
            $self->getNormalizedLogName('stderr'));
    }else{
        $self->addMessage(
            'Cannot copy log file ['.$self->remote_err."]: $res");
    }

    $res = $testp->getFile( $self->remote_out,
            $self->getNormalizedLogName('stdout'));
    my $pr = 100;
    if($res == 0){
        $self->registerLogFile('stdout',
            $self->getNormalizedLogName('stdout'));
        $pr = $self->processLogs
            ($self->getNormalizedLogName('stdout'));
    }else{
        $self->addMessage(
            'Cannot copy log file ['.$self->remote_out."]: $res");
    }
    #calculate results status
    if($killed > 0){
        $self->addYE('killed','yes');
        $self->fail(
                'Killed by timeout after ['.
                ($kt-$starttime).
                '] sec of execution');
    }else{
        $self->addYE('killed','no');
        $self->addYE('exitcode',$testp->exitcode);
        if( ($testp->exitcode == 0) && ($pr == 0) ){
            $self->pass;
        }elsif(($testp->exitcode == 0) && ($pr == 1)){
            $self->skip(1,$self->getReason);
        }else{
            $self->fail($self->getReason);
        }
    }

    ### cleanup logs
    ### end
    #no idea what is good result there, so no return
    #$self->test->tap     ( $self->tap);
    $self->test->results ($self->yaml);
    #$self->write();
    #return $self->tap();
}

sub _getMasterClient{
    my $self = shift;
    foreach my $lc (@{$self->env->getClients}){
        DEBUG "Check client ". Dumper $lc;
        return $lc
            if(defined( $lc->{'master'} &&
                ( $lc->{'master'} eq 'yes')));
    }
    return undef;
}

sub _addCmdLogFiles{
    my $self = shift;
    #TODO add random part
    my $r = int rand 1000000 ;
    my $tee = " | tee ";

    $self->options->{'cmdout'} = 0
        unless defined  $self->options->{'cmdout'} ;

    $tee = " 1>  " if  $self->options->{'cmdout'} == 0 ;
    $self->remote_err( "/tmp/test_stderr.$r.log");
    $self->remote_out( "/tmp/test_stdout.$r.log");
    $self->cmd( $self->cmd ." 2>     ".$self->remote_err.
                            $tee.$self->remote_out);
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

