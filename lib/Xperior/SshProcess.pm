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

Xperior::SshProcess - The module implements remote process control for single
process over ssh

=head1  DESCRIPTION

The module is specially designed to be easily replaced by other module which
provide same interface, possible via other protocol.

Modules support two serial workflows, opposed to a parallel, that a user is
resposible to control.

=over 2

=item Workflow 1

User creates long-time process on remote nodes, the process is executed in
background on a target node and deattached from console.
The stderr/stdout capturing and download is a user responsibility, that can be
done, for example, by standard output rediction via command line.

Functions to be used: B<create>, B<kill>, B<isAlive> and fields B<exitcode> and
B<pid>.

=item Workflow 2

Create short-time process on remote nodes with capturing stderr/stdout. It
behaves as perl B<``> (backtics) command.

Function to be used: B<run> and field B<exitcode> in returned hash

=back

=cut

package Xperior::SshProcess;
use Moose;
use MooseX::ClassAttribute;

#TODO enable after adding  package to common setup
#use namespace::autoclean;
use English;
use Data::Dumper;
use Cwd qw(chdir);
use File::chdir;
use File::Path;
use File::Temp qw(:mktemp);
use File::Slurp qw(write_file read_file);
use Log::Log4perl qw(:easy);
use Carp;
use Proc::Simple;
use Xperior::Utils;
use Time::HiRes;
use File::Basename;

# Do not assign anything, because it is determined in BEGIN block
my $UserKnownHostsFile;
my $UserKnownHostsFileBr;
BEGIN {
    my $f;
    ($f, $UserKnownHostsFile)   = mkstemp("/tmp/ssh_user_known_hosts_file_XXXXXXXXXXX");
    close $f;
    ($f, $UserKnownHostsFileBr) = mkstemp("/tmp/ssh_user_known_hosts_file_XXXXXXXXXXX");
    close $f;
    unlink $UserKnownHostsFile;
    unlink $UserKnownHostsFileBr;
}

END {
    unlink $UserKnownHostsFile;
    unlink $UserKnownHostsFileBr;
}


with qw(MooseX::Clone);

=head2 Fields

=head3 port

Port which is used for ssh connection

=head3 host

Host which is used for ssh conenction

=head3 user

User which is used for ssh connection, no default

=head3 exitcode

Exit code from latest executed command via C<create> call.

=head3 syncexitcode

Exit code from latest executed command via C<createSync> call.

=head3 killed

Flag set if killed latest executed command via C<create> call.

=cut

class_has ssh_default_timeout
            => ( is => 'rw', default => 30);
class_has start_attempts
            => ( is => 'rw', default => 5);

has port           => ( is => 'rw' );
has host           => ( is => 'rw' );
has user           => ( is => 'rw' );
has pass           => ( is => 'rw' );
has cert           => ( is => 'rw' );
has bridge         => ( is => 'rw' );
has bridgeuser     => ( is => 'rw', default => 'root');


has pidfile        => ( is => 'rw' );
has ecodefile      => ( is => 'rw' );
has controlmaster  => ( is => 'rw' );
has rscrfile       => ( is => 'rw' );
has pid            => ( is => 'rw' );
has appname        => ( is => 'rw' );
has exitcode       => ( is => 'rw' );
has syncexitcode   => ( is => 'rw' );
has bprocess       => ( is => 'rw' );
has masterprocess  => ( is => 'rw' );

has killed         => ( is => 'rw' );
has hostname       => ( is => 'rw' );
has osversion      => ( is => 'rw' );

has bridgetmpdir           =>(
    is => 'ro', default => '/tmp/xperior_bridge_dir');
has sync_timeout_exit_code => (
    is => 'ro', default => -100);
has stdout_delimiter => (
    is => 'ro', default =>
    '=================xperior_stdout_SshProcess_delimiter===============');
has stderr_delimiter => (
    is => 'ro', default =>
    '=================xperior_stderr_SshProcess_delimiter===============');

has term_signal         => ( is => 'rw', default => 'TERM' );
has kill_signal         => ( is => 'rw', default => 'KILL' );
has kill_success        => ( is => 'ro', default => -99 );
has error_kill_failure  => ( is => 'ro', default => -98 );
has error_pid_exist_after_kill  => ( is => 'ro', default => -97 );

=back

=head2 Functions

=cut

=head3 _kill

Function implement 2-level kill, first attempt is SIGTERM,
second is SIGKILL.

Parameters:
 $proc - Proc::Simple object

No result returned

=cut

sub _kill{
    my ($self, $proc) = @_;
    DEBUG "Send SIGTERM";
    my $k0 = $proc->kill();
    if($proc->exit_status()){
        DEBUG "SIGTERM was successful";
    }else{
        DEBUG "Send SIGKILL, SIGTERM results is $k0";
        my $k1 = $proc->kill("SIGKILL");
        DEBUG "SIGKILL result is $k1";
    }
    return;
}



=head3 _supportMasterProcess

Function start and support ssh master chanell

=cut

sub _supportMasterProcess{
    my $self = shift;
    if( ( defined $self->masterprocess() ) and
        ( $self->masterprocess->poll())){
        DEBUG "Ssh-master already  started, ignoring";
        return;
    }
    if($self->bridge){
        WARN ('Master is not supported for bridge');
        return -1;
    }
    DEBUG 'Starting master process for ['.
    $self->controlmaster()."]";

    $self->masterprocess( Proc::Simple->new() );
    unlink $self->controlmaster();
    my $mc =
       "ssh -n -N "
      . "-o  'BatchMode=yes' "
      . "-o 'AddressFamily=inet' "
      . "-o 'UserKnownHostsFile=$UserKnownHostsFile' "
      . "-o 'StrictHostKeyChecking=no' "
      . "-o 'ConnectTimeout=25' "
      . " -o 'ControlMaster=yes' "
      . " -o 'ControlPath=".$self->controlmaster()."' "
      . $self->_getPortSshCmd()
      . $self->_getCertSshCmd()
      . $self->user . "@"
      . $self->host;
    DEBUG "Master cmd is [$mc]";
    $self->masterprocess->start($mc);
    $self->masterprocess->kill_on_destroy(1);
    $self->masterprocess->signal_on_destroy("KILL");
    DEBUG 'Master started for ['.$self->controlmaster().']';
}

=head3 _getPortSshCmd

Return ssh cmd part for port parameter

=cut

sub _getPortSshCmd{
    my ($self) = @_;
    if($self->port() and $self->port() != 22){
        return ' -p '.$self->port().' ';
    }
    return ' ';
}


=head3 _getPortSshCmd

Return ssh cmd part for port parameter

=cut

sub _getCertSshCmd{
    my ($self) = @_;
    if($self->cert()){
        return ' -i '.$self->cert().' ';
    }
    return ' ';
}



=head3 _getPortScpCmd

Return scp cmd part for port parameter

=cut

sub _getPortScpCmd{
    my ($self) = @_;
    if($self->port() and $self->port() != 22){
        return ' -P '.$self->port().' ';
    }
    return ' ';
}

=head3 _getMasterCmd

Function returns prepared part of ssh command for executing
with socket multiplexing.

=cut

sub _getMasterCmd{
    my ($self) = @_;
    my $socket = $self->controlmaster();
    if($self->bridge()){
        $socket = $socket.'_on_bridge';
    }
    return
        " -o 'ControlMaster=no' ".
        " -o 'ControlPath=".$self->controlmaster()."' ";
    #" -o ControlPersist=".(60*60)." "; only ssh 6.x option
}

=head3 _getBridgeCmd(mode)

Function returns prepared part of sshcommand for executing
via bridge.

Return empty line if bridge is not set.

If parameter set to 'bg' then 'ssh .. -f..' will be returned which useful
for moving ssh to backgroudn asap.

=cut

sub _getBridgeCmd{
    my $self  = shift;
    my $async = shift || '';
    $async = '-f' if($async and ($async eq 'bg'));
    if($self->bridge()){
      return
        "ssh -T "
      . " -o 'AddressFamily=inet' "
      . " -o 'UserKnownHostsFile=$UserKnownHostsFileBr' "
      . " -o 'StrictHostKeyChecking=no' "
      . " -o 'ConnectTimeout=25' "
      . " -o  'BatchMode=yes' "
      . " $async "
      . $self->bridgeuser().'@'.$self->bridge(). " ";
    }else{
        return '';
    }
}

#TODO speed improvement via socket sharing

#hint:
#ssh exits with the exit status of the remote command which can be find with echo $? command.
#Or value 255 is return, if an error occurred while processing request via ssh session
#65280 - FF for script case return

#do pool check status to prevent false deatch report
sub _sshSyncExec {
    my ( $self, $cmd, $timeout, $need_tty ) = @_;
    $timeout = $self->ssh_default_timeout()
                    unless defined $timeout;
    my $step = 0;
    my $AT   = 5;
    my $r    = undef;
    while ( $step < $AT ) {
        sleep $step;
        # legacy behavior support
        $self->syncexitcode(undef);
        $r = $self->_sshSyncExecS( $cmd, $timeout, $need_tty );
        if (( defined( $r->{sshexitcode} ) )
              and ( $r->{sshexitcode} != 255 )){ #connect fault
            $r->{attempts}=$step+1;
            return $r;
          }
        $step++;
        my $ec = $r->{sshexitcode};
        DEBUG "Sync attemp [$step], ssh exit code is :[$ec], retry...";
    }
    $r->{attempts}=$step;
    return $r;
}

sub _sshSyncExecS {
    my ( $self, $cmd, $timeout, $need_tty ) = @_;
    $self->_supportMasterProcess();
    my $nonbridgeparams =
        "-o  'BatchMode=yes' " .
        "-o 'AddressFamily=inet' ";
    my $ttyopt = $need_tty ? " -t -t " : "";
        #." -f ";
    my $bridgecmd = $self->_getBridgeCmd();
    $nonbridgeparams= '' if($bridgecmd);
    my $cc =
      $bridgecmd
      . "ssh  "
      . $ttyopt
      . $nonbridgeparams
      . " ". $self->_getMasterCmd()
      . "-o 'ConnectTimeout=25' "
      . "-o 'UserKnownHostsFile=$UserKnownHostsFile' "
      . "-o 'StrictHostKeyChecking=no' "
      . "-o 'ConnectionAttempts=3' "
      . "-o 'ServerAliveInterval=600' "
      . "-o 'ServerAliveCountMax=15' " #. " -f "
      . $self->_getPortSshCmd()
      . $self->_getCertSshCmd()
      . $self->user . "@"
      . $self->host
      . " \"$cmd; ec=\\\$? ;echo -n 'Internal_exit_code:'; echo -n \\\$ec; exit 0 \"";
    DEBUG "Remote ssh sync cmd is [$cc], timeout is [$timeout]";
    my ($f,$stdout,$stderr);
    ($f, $stdout)   = mkstemp("/tmp/ssh_sync_stdout_XXXXXXXXXXX");
    close $f;
    ($f, $stderr)   = mkstemp("/tmp/ssh_sync_stderr_XXXXXXXXXXX");
    close $f;
    my $proc = Proc::Simple->new();
    $proc->redirect_output ($stdout, $stderr);
    $proc->start($cc);
    $proc->kill_on_destroy(1);
    $proc->signal_on_destroy("KILL");
    my $time = time();
    my $killed = 0;
    my $exitcode=-1;
    my $parsed_exit_code =-1;
    while ( $proc->poll() ) {
        DEBUG "Wait for sync app finish";
        sleep 1;
        #DEBUG 'sleep 1 ' . `/bin/sleep 1`;    #hack, looks like perl's sleep
                                              #doesn't work there
        if ( ($time + $timeout) < time() ) {
            # legacy behavior support
            $self->syncexitcode($self->sync_timeout_exit_code);
            $self->killed(time);
            ###
            $killed=time;
            $exitcode         = $self->sync_timeout_exit_code;
            $parsed_exit_code = $self->sync_timeout_exit_code;
            WARN "SSH sync execution killed by timeout !\n";
            $self->_kill($proc);
            last;
        }
     }
    my @outraw = read_file($stdout);
    my $out = join( "\n", map {
            #DEBUG "line:".$_;
            my $str = $_;
            if( $str =~ s/Internal_exit_code:(\d+)// ){
                DEBUG "Caught exit code $1";
                $parsed_exit_code = $1;
                # $_ =~ s/Internal_exit_code:(\d++)$//;
            }
            $str;
        } @outraw );
    my $err = read_file($stderr);
    unlink $stdout;
    unlink $stderr;
    if(not $killed){
        DEBUG 'SSH exit code is :'.($proc->exit_status() >> 8);
        $exitcode = $proc->exit_status() >> 8;
        # legacy behavior support
        $self->syncexitcode( $proc->exit_status() >> 8 );
    }
    $self->syncexitcode( $parsed_exit_code );
    return {stdout=>$out, stderr=>$err,
        exitcode=>$parsed_exit_code, sshexitcode=>$exitcode, killed => $killed};

}

sub _sshAsyncExec {
    my ( $self, $cmd, $timeout ) = @_;
    my $asyncstarttimeout = $self->ssh_default_timeout();
    my $sc                = 1;
    my $nonbridgeparams =
         "-o  'BatchMode=yes' "
        ."-o 'AddressFamily=inet' "
        ." -f ";
    $nonbridgeparams= '' if($self->_getBridgeCmd());
    my $cc =
      $self->_getBridgeCmd('bg')
      . "ssh "
      . $nonbridgeparams
      . "-o 'UserKnownHostsFile=$UserKnownHostsFile' "
      . "-o 'StrictHostKeyChecking=no' "
      . "-o 'ConnectTimeout=25' "
      . $self->_getCertSshCmd()
      . $self->_getPortSshCmd()
      . $self->user . "@"
      . $self->host
      . " \"$cmd\"  ";
    DEBUG "Remote cmd is [$cc]";
    my $step = 0;
    my $AT   = $self->start_attempts();

    #this cycle is workaround for connection problem,
    #which observed too rare.
    while ( ( $sc != 0 ) and ( $step < $AT ) ) {
        $self->_supportMasterProcess();
        $self->bprocess( Proc::Simple->new() );
        $self->bprocess->start($cc);
        $self->bprocess->kill_on_destroy(1);
        my $time = 0;
        while (not defined $self->bprocess->exit_status()) {
            #DEBUG 'sleep 1 ' . `/bin/sleep 1`;    #hack, looks like perl's sleep
            #                                      #doesn't work there
            DEBUG "Wait for sync app finish";
            sleep 1;
            $sc = $self->bprocess->exit_status();
            $time++;
            if ( $time > $asyncstarttimeout ) {
                ERROR "App alive more then $asyncstarttimeout seconds, kill it";
                #$self->bprocess->kill();
                $self->_kill($self->bprocess);
                last;
            }
        }
        $sc = $self->bprocess->exit_status();
        $step++;
    }
    return $sc;
}

=head3 DEMOLISH

Desctructor. Cleanup master socket files.

=cut

sub DEMOLISH{
    my $self = shift;
    if(defined $self->controlmaster()){
        unlink
        $self->controlmaster();
    }
    return;
}

=head3 initTemp ()

Initialize temporary variables.

=cut

sub initTemp {
    my $self = shift;
    my $id   = Time::HiRes::gettimeofday();
    $self->pidfile("/tmp/xperior_pid_ssh_$id");
    $self->ecodefile("/tmp/remote_exit_code_$id");
    $self->rscrfile("/tmp/remote_script_$id.sh");
    $self->controlmaster("/tmp/xperior_controlmaster"
            ."_".$self->host()
            ."_".Time::HiRes::gettimeofday()
            .".sshmaster");
    $self->masterprocess(undef);
    return;
}

=head3 init ([\Xperior::Node] || [$host, $user, $port])

Initialize module, attempt to connect it. Only ssh is supported.
Master channel is create also there (for bridge-less env)

Parameters:
        Xperior::Node
    or
        host, user, port

Exit codes:
    0   - success
    -99 - initialization failed or host unreachable

Notes
    Port is not used now

Example:

    my $sc = Xperior::SshProcess->new();

    if ($sc->init($self) < 0){
        $self->rconnector(undef);
        return undef;
    }


=cut


sub init {
    DEBUG "Xperior::SshUnixProcess->init";
    my $self = shift;
    my $param1 = shift;
    if( ref($param1) and $param1->isa( 'Xperior::Node' )){
        my $node=$param1;
        DEBUG "Xperior::SshUnixProcess->init, new initialization";
        $self->host($node->ip());
        $self->user($node->user());
        $self->port($node->port());
        $self->bridge($node->bridge());
        $self->bridgeuser($node->bridgeuser()) if $node->bridgeuser();
        $self->cert($node->cert()) if $node->cert();
    }else{
        DEBUG "Xperior::SshUnixProcess->init, old initialization";
        $self->host($param1);
        $self->user(shift);
        $self->port(shift);
    }
    my $nocrash = shift;

    $self->initTemp();
    $self->killed(0);
    $self->exitcode(0);

    my ($ver, $unameres);
    $unameres = $self->_sshSyncExec(
                "uname -a",
                $self->ssh_default_timeout());
    if(defined($unameres)){
        $ver = trim($unameres->{stdout});
    }else{
        $ver='';
    }

    #DEBUG "-------------------------------";
    #DEBUG $self->exitcode;
    #DEBUG $self->killed;
    if (( not defined $unameres )
               or ( $unameres->{exitcode} != 0 )
               or ( $unameres->{killed} != 0 ) )
    {
        WARN "SshProcess cannot be initialized(uname)";
        return -99;
    }

    my $h = $self->_sshSyncExec(
                    "hostname",
                    $self->ssh_default_timeout());
    if(defined($h)){
        $h = $h->{stdout};
        $h = trim $h;
    }else{
        $h='';
    }
    if( $h eq '' )
    {
        WARN "SshProcess cannot be initialized(hostname)";
        return -99;
    }
    $self->hostname($h);
    $self->osversion($ver);
    DEBUG "Initialized ssh process on host [$h] version [$ver]";
    return 0;
}

#TODO test on it
sub _findPid {
    my $self = shift;
    $self->pid(undef);
    my $res = $self->_sshSyncExec(
                        "cat " . $self->pidfile,
                        $self->ssh_default_timeout() )
                            || return;

    foreach my $s ( split( /\n/, $res->{stdout} ) ) {
        DEBUG "Check line for PID [$s]\n";
        my ($pid) = ($s =~ m/^(\d+)/x);
        if ($pid) {
            $self->pid($pid);
            DEBUG "PID found: [$pid]\n";
            return $pid;
        }
    }
    return 0;
}

=head3 run ($command, $timeout)

Safe version of createSync, executes  command on remote
node same as system. If timemout is exceeded process will
be killed. Stdout, stderr gathered to scalar vars, this mean
that output should be comparably small.

Command could be multiline shell script. 5 attempts will be done
if ssh exit code 255.

From ssh help
    ssh exits with the exit status of the remote command or with 255
    if an error occurred.

Parameters:

  * command to run
  * opt => value

  Supported options
  timeout  - number 5 sec
  need_tty - 1 if ssh tty is needed. use carefully.

Return value is hash ref of:

  * stdout      - stdout from remote process
  * stderr      - stderr from remote process
  * exitcode    - exit code from remote process
  * sshexitcode - ssh exit code
  * killled     - if not 0 mean process was killed by timeout
  * attempts    - how much conenction attempts were done

or

Parameters:

  * B<array> of command to run
  * common timeout for all commands
  and previously defined opts

In this set of parameters, all commands  merged to one
script via separator and stdout/stderr split after
finish for every subcommand. In theory, it can't
be error-free but for small text output it should be ok.

Return value is hash ref of:

  * array of stdouts - stdout from remote process
  * stdoutraw        - merged stdouts with delimiters
  * stderrraw        - merged stderrs with delimiters
  * array of stderr  - stderr from remote process
  * exitcode         - target app exit code, -1 if ssh failed
  * sshexitcode      - ssh exit code
  * killled          - if not 0 mean common process was killed by timeout
  * attempts         - how much conenction attempts were done

obj->syncexitcode is set by function but please don't use it!

=cut

sub run{
    my ( $self, $app, %opts ) = @_;
    my $timeout = $opts{timeout};
    my $need_tty = $opts{need_tty} or 0;
    my $cmdarray=0;
    DEBUG "Xperior::SshProcess->run on host ". $self->host . "]";
    my $tef = $self->rscrfile;
    my ($f, $t) = mkstemp("/tmp/ssh_remote_sync_script_XXXXXXXXXXX");
    close $f;
    if(ref($app) eq 'ARRAY'){
        $cmdarray=1;
        my $delimiters =
        "\n".
        'echo  '.$self->stdout_delimiter."\n".
        'echo  '.$self->stderr_delimiter." 1>&2 \n";
        $app = join($delimiters,@$app);

    }
    $app = "#!/usr/bin/env bash \n".
           "set -x\n".$app;
    DEBUG "Uploading script:\n$app";
    write_file($t, $app);
    $self->putFile($t, $tef);
    unlink $t;
    my $execres =  $self->_sshSyncExec( "sh $tef", $timeout , $need_tty);
    if($cmdarray){
        $execres->{stdoutraw} = $execres->{stdout};
        $execres->{stderrraw} = $execres->{stderr};
        my @ao = map {trim($_)} split($self->stdout_delimiter,$execres->{stdout});
        $execres->{stdout}= \@ao;
        my @ae = map {trim($_)} split($self->stderr_delimiter,$execres->{stderr});
        $execres->{stderr}= \@ae;
    }
    return $execres;
}


=head3 createSync ($command, $timeout)

Deprecated!

Executes remote process and catch stderr/std and exit code. Function exits when
remote execution done.

Parameters:

  * command to run, could be multiline shell code
  * timeout

Return values:

  * stdout from executed command
  * obj->syncexitcode - exit code from script

=cut

sub createSync {
    my ( $self, $app, $timeout ) = @_;
    DEBUG "Xperior::SshProcess createSync";
    DEBUG "App to run [$app] on host[" . $self->host . "]";
    #my $ecf = $self->syncecodefile;
    $self->killed(0);
    $self->syncexitcode(undef);
    my $sscript = <<"SSCRIPT";
$app
SSCRIPT

    DEBUG "Uploading script:\n$sscript";
    my $tef = $self->rscrfile;
    my ($f, $t) = mkstemp("/tmp/ssh_remote_sync_script_XXXXXXXXXXX");
    close $f;
    write_file($t, $sscript);
    $self->putFile($t, $tef);
    unlink $t;
    my $sr = $self->_sshSyncExec( "sh $tef", $timeout );
    DEBUG "Remote app completed";
    INFO trim($sr->{stderr}) if trim($sr->{stderr});
    return undef
        if $sr->{killed};
    return $sr->{stdout};

}

=head3 create ($name, $command)

Execute remote process with unattached stderr/stdout and exit.
Pid is savednon remote fs. Exit code is saved after process end.

Parameters:

=over 4

=item $name

name of process which can be seen on remote node. Can be used in B<killall> call. Now is not used somehow. TBI.

=item $command

command line which will be executed on remote node

=back

Returns:

=over 4

=item 0

Successful start

=item -1

Cannot find remote process

=item -2

Cannot start application

=item -3

Cannot send cmd file to target node

=back


=cut

sub create {
    my ( $self, $name, $cmd ) = @_;
    chomp ($cmd);
    DEBUG "Starting remote shell command in background on host '$self->{host}'";
    DEBUG "[$cmd]";

    $self->appname($name);
    $self->killed(0);

    my $shell_file = $self->rscrfile();
    my $err_file   = $self->ecodefile();
    my $pid_file   = $self->pidfile();

    DEBUG "Del remote pid file: $pid_file";
    my $rd = $self->_sshSyncExec( "rm -rf " . $pid_file );

    my $script = <<"SCRIPT";
#!/usr/bin/env bash
set -x
$cmd &
pid=\$!
echo \$pid > $pid_file
wait \$pid
echo \$? > $err_file
SCRIPT

    DEBUG "Uploading script:\n$script";
    my ($f, $t) = mkstemp("/tmp/ssh_remote_script_XXXXXXXXXXX");
    close $f;
    write_file($t, $script);
    if( $self->putFile($t, $shell_file) !=0 ){
        ERROR 'Cannot send cmd file to ['.
            $self->host.':'.$self->_getPortScpCmd().']';
        unlink $t;
        return -3;
    }
    unlink $t;
    if ( $self->_sshAsyncExec("sh $shell_file") ) {
        WARN "Cannot create remote process";
        return -2;
    }
    DEBUG "Remote async app started";
    sleep 1;
    $self->exitcode(undef);

    #cycle workaround for long remote part start
    # wait 5*1 sec for pid file on remote side
    my $i   = 0;
    my $pid = 0;
    while((not $pid) and ( $i < 5)){
        $pid = $self->_findPid();
        sleep 1 if not $pid;
        $i++;
    }

    unless ($pid) {
        #confess
        WARN "Remote process doesn't start or isn't found in pid file";
        return -1;
    }

    return 0;
}

=head2 check_get_alive_pids_remote($pids)

Check process status for PIDs on remote node from $pids, return alive pids.

=cut

sub check_get_alive_pids_remote {
    my ($self, $cpids) = @_;
    return 0 unless $cpids;
    my @cpids = ();
    my @alive_cpids = split(/\s+/, $cpids);
    foreach my $p (@alive_cpids) {
        my $execrc = $self->run("kill -0 $p 2> /dev/null; echo \$?");
        my $ec = $execrc->{stdout};
        if($ec != 0 ) {
            DEBUG "Process [$p] does not exist";
        } else {
            DEBUG "Process [$p] alive";
            push(@cpids, $p);
        }
    }
    if(@cpids) {
        my $alive_cpids = join(" ", @cpids);
        return $alive_cpids;
    } else {
        return 0;
    }
}

=head2 get_child_pids()

Get all the cpids running on remote lustre node into a scalar var from stdout.
Find cpids, reverse the order of cpids so that newest child is terminated
first, return back all pids in a array.

=cut

sub get_child_pids {
    my $self = shift;
    return -3 unless $self->pid; #ESRCH 3 No such process
    my $pid = $self->pid;

    my $execres = $self->run("ps_op=\$(ps --no-heading axo pid,pgid);
        echo \$ps_op");
    my $ps_op = $execres->{stdout};
    return 0 unless $ps_op;
    my %pid_gid_map = split(/[\n\s]/, $ps_op);

    # Get gid of "$pid"
    my @expected_pid = grep { $pid == $_ } keys %pid_gid_map;
    # There would always be one pid in array.
    my $exp_pid = $expected_pid[0];
    my $gid = $pid_gid_map{$exp_pid};
    DEBUG "GID is $gid";

    return -3 unless $gid;
    # Get all pids which are related to above found GID.
    my @pids = grep { $pid_gid_map{$_} == $gid } keys %pid_gid_map;
    # We don't need to kill grand parent process(remote sript)
    my @cpids_wo_gid = grep { $gid != $_ } @pids;

    # Sort it so that lustre log callector process is killed last. Generally
    # log collectors(of any application) are started in very begining for
    # collecting all the info. So we should kill it last so that all the info
    # is collected before it gets killed.
    my @cpids = sort { $a <=> $b } @cpids_wo_gid;
    my $cpids = join(' ', @cpids);
    chomp $cpids;
    DEBUG "cpids are $cpids Owned pid is:" . $pid;
    return $cpids;
}

=head2 kill_tree($self, $kill_time)

Send TERM to $pid on remote node, sleep $kill_time sec, check processes alive,  and if alive
- send KILL on remote node.

=cut

sub kill_tree {
    my ( $self, $kill_time ) = @_;
    my $name = $self->appname || '';
    my $rc = 0;
    $kill_time = 1 unless $kill_time;
    my $cpids = $self->get_child_pids();
    if ($cpids == -3) {
        WARN "App not alive";
        return;
    } elsif (!$cpids) {
        WARN "Some error occured while getting ps cmd output";
        return;
    }
    my $sigterm = $self->term_signal();
    my $sigkill = $self->kill_signal();

    DEBUG "cmd is- kill -$sigterm $cpids";
    $rc = $self->_sshSyncExec("kill -$sigterm $cpids");
    $self->exitcode($self->kill_success()) unless $rc->{sshexitcode};

    # time to system kill and cleanup for highloaded systems
    sleep $kill_time;
    my $alive_cpids = $self->check_get_alive_pids_remote($cpids);
    DEBUG "Proc status after TERM (pids alive):". $alive_cpids;
    $self->exitcode($self->error_kill_failure()) if $rc->{sshexitcode};

    if($alive_cpids) {
        DEBUG "cmd is- kill -$sigkill $alive_cpids";
        $rc = $self->_sshSyncExec("kill -$sigkill  $alive_cpids");
        return if $rc->{sshexitcode};
        DEBUG "***[$name:$alive_cpids]*** Killed!";
        my $new_alive_cpids = $self->check_get_alive_pids_remote($cpids);
        DEBUG "Proc status after KILL (pids alive):". $new_alive_cpids;
        if($new_alive_cpids) {
            WARN "Pids still alive after KILL:". $new_alive_cpids;
            $self->exitcode($self->error_pid_exist_after_kill());
            return;
       }
    }
    $self->killed(time);
}


=head3 kill ($mode)

Kill process which was created by create via saved pid.

=cut

sub kill {
    my ( $self, $mode ) = @_;
    DEBUG "Xperior::SshProcess->kill";
    my $pid  = $self->pid;
    my $name = $self->appname || '';
    $mode = 0 unless defined $mode;

    if ( ( !defined($pid) ) or ( $pid eq '' ) ) {
        DEBUG "PID is empty, nothing to be killed";
        return;
    }

    DEBUG "Killing remote process [$name:$pid], mode [$mode]";
    if ( $mode == 0 ) {
        $self->_sshSyncExec("kill -15 $pid");
        sleep 10;
    }
    $self->_sshSyncExec("kill -9  $pid");
    $self->killed(time);
    $self->bprocess->kill;
    DEBUG "[$name:$pid]*** Killed!";
    $self->exitcode(-99);
}

=head3 isAlive

Check process status on remote system via saved pid. Also this function get
exit code from remote side if application is exited or killed.

=cut

#sub isAlive {
#    DEBUG "Xperior::SshProcess->isAlive";
#    my $self = shift;
#    my $pid  = $self->pid;
#    my $name = $self->appname;
#    my $o    = trim $self->_sshSyncExec(" kill -0 $pid 2>&1; echo \$? ");
#    unless ( defined($o) ) {
#        ERROR "unable to check remote system: [$o]";
#        return -99;
#    }
#
#    if ( $o =~ m/^0$/ ) {
#        DEBUG "Remote process is alive! ";
#        return 0;
#    }
#    $self->exitcode( trim $self->_sshSyncExec( "cat " . $self->ecodefile ) );
#    DEBUG "Remote process is not found! ";
#    return -1;
#}

sub isAlive {
    DEBUG "Xperior::SshProcess->isAlive";
    my $self = shift;
    my $pid  = $self->pid;
    return -100 unless $pid;
    my $name = $self->appname;
    my $step     = 1;
    my $AT       = 6;
    my $exitcode = '';
    my $o = '';
    while ( $AT > $step ) {
        my $execres = $self->_sshSyncExec(
                    " ps -o pid=  -p $pid h 2>&1; echo \$? ");
        if ( defined($execres) ) {
            $o = trim $execres->{stdout};
        }
        if ( ( defined($o) ) and ( $o =~ m/^\s*$pid\s*/x ) ) {
            last;
        }
        my $ecoderes =  $self->_sshSyncExec( "cat " . $self->ecodefile );
        $exitcode = trim( $ecoderes->{stdout} );

        DEBUG "Exitcode = [$exitcode]";
        if ( ( defined($o) ) and ( $exitcode =~ m/^\d+$/x ) ) {
            last;
        }
        sleep $step;
        $step++;
        DEBUG "Proc is not found, <$step> recheck process status";
    }
    DEBUG "Alive check cycle done";

    #  DEBUG "*********** $o";
    unless ( defined($o) ) {
        ERROR "unable to check remote system, no output got";
        return -99;
    }

    if ( $o =~ m/^\s*$pid\s*/x ) {
        DEBUG "Remote process is alive! ";
        return 0;
    }
    $self->exitcode($exitcode);
    DEBUG "Remote process is not found, sync exit code is: ["
      . $self->syncexitcode
      . "], app exit code is :["
      . $self->exitcode
      . "], \n o=[$o]";
    return -1;
}

=head3 putFile ($local_file, $remote_file [, $timeout])

Put fileto remote system.
Timeout is optional, in secs, default is 10 min

Return 0 if file copied and scp exit code if error occurred.

=cut

sub putFile {
    my ( $self, $local_file, $remote_file, $timeout) = @_;

    my($filename, $dirs, $suffix) = fileparse("$remote_file");
    my $tmp_file = $self->bridgetmpdir().'/'.$filename;

    if( (not $remote_file) or ($remote_file  =~ m/^\/\s*$/x)){
        ERROR "Remote target is incorrect or not set:[$remote_file]";
        return 110;
    }
    $timeout = 600 if not $timeout;

    my $targethost  = $self->user.'@'.$self->host;
    my $destination = $targethost.':'.$remote_file;
    $self->_supportMasterProcess();
    if( $self->bridge() ){
        DEBUG "Copying $local_file to $destination via bridge";
        my $bridgetmpdir = $self->bridgetmpdir();
        my $bridgeuser   = $self->bridgeuser();
        my $bridgehost   = $self->bridge();
        my $bridgecmd    = $self->_getBridgeCmd();
        my $script = <<"PSCRIPT";
        $bridgecmd mkdir -p $bridgetmpdir
        scp -rp -o 'UserKnownHostsFile=$UserKnownHostsFile' \\
            -o 'StrictHostKeyChecking=no'                   \\
            -o 'ConnectionAttempts=3'                       \\
            -o 'ConnectTimeout=25'                          \\
        $local_file $bridgeuser\@$bridgehost:$tmp_file

        $bridgecmd                                            \\
            scp -rp -o 'UserKnownHostsFile=$UserKnownHostsFile' \\
                -o 'StrictHostKeyChecking=no'                   \\
                -o 'ConnectionAttempts=3'                       \\
                -o 'ConnectTimeout=25'                          \\
            $tmp_file $destination
       $bridgecmd  rm -fv $tmp_file

PSCRIPT
        DEBUG "Save put script:\n$script";
        my ($f, $t) = mkstemp("/tmp/ssh_put_script_XXXXXXXXXXX");
        close $f;
        write_file($t, $script);
        #my $res = shell("sh -e $t");
        my $res = runEx("sh -e $t", 0, "", $timeout);
        unlink $t;
        return $res;


    }else{
        DEBUG "Copying $local_file to $destination";
#        my $e = shell( [
#            "scp", "-rp ",
#                "-o 'UserKnownHostsFile=$UserKnownHostsFile'",
#                "-o 'StrictHostKeyChecking=no'",
#                "-o 'ConnectionAttempts=3'",
#                "-o 'ConnectTimeout=25'",
#                "$local_file $destination" ] );
        my $e = runEx(
            "scp -rp ".
            " -o 'UserKnownHostsFile=$UserKnownHostsFile'".
            " -o 'StrictHostKeyChecking=no'".
            " -o 'ConnectionAttempts=3'".
            " -o 'ConnectTimeout=25' ".
            $self->_getMasterCmd().
            $self->_getPortScpCmd('yes').
            " $local_file $destination", 0, "", $timeout );

        return $e;
    }
}

=head3 getFile ($remote_file, $local_file)

Copy file from remote system to local.
Timeout is optional, in secs, default is 10 min

Return 0 if file copied and scp exit code if error occurred.

=cut

sub getFile {
    my ( $self, $remote_file, $local_file, $timeout ) = @_;
    my($filename, $dirs, $suffix) = fileparse("$remote_file");
    my $tmp_file = $self->bridgetmpdir().'/'.$filename;
    $timeout = 600 if not $timeout;
    my $source  = $self->user . '@' . $self->host . ':' . $remote_file;
    $self->_supportMasterProcess();
    if( $self->bridge() ){
        DEBUG "Copying [$source] to [$local_file] via bridge";

        my $bridgetmpdir = $self->bridgetmpdir();
        my $bridgeuser   = $self->bridgeuser();
        my $bridgehost   = $self->bridge();
        my $bridgecmd    = $self->_getBridgeCmd();

        my $script = <<"PSCRIPT";

        $bridgecmd mkdir -p $bridgetmpdir
        $bridgecmd                                              \\
            scp -rp -o 'UserKnownHostsFile=$UserKnownHostsFile' \\
                -o 'StrictHostKeyChecking=no'                   \\
                -o 'ConnectionAttempts=3'                       \\
                -o 'ConnectTimeout=25'                          \\
            $source $tmp_file

            scp -rp -o 'UserKnownHostsFile=$UserKnownHostsFile' \\
                -o 'StrictHostKeyChecking=no'                   \\
                -o 'ConnectionAttempts=3'                       \\
                -o 'ConnectTimeout=25'                          \\
            $bridgeuser\@$bridgehost:$tmp_file $local_file
       $bridgecmd  rm -fv $tmp_file

PSCRIPT
        DEBUG "Save put script:\n$script";
        my ($f, $t) = mkstemp("/tmp/ssh_put_script_XXXXXXXXXXX");
        close $f;
        write_file($t, $script);
        #my $res = shell("sh -e $t");
        my $res = runEx("sh -e $t", 0, "", $timeout);
        unlink $t;
        return $res;

    }else{
        DEBUG "Copying [$source] to [$local_file]";
#        my $e = shell([
#             "scp", "-rp", "-o 'UserKnownHostsFile=$UserKnownHostsFile'",
#                 "-o 'StrictHostKeyChecking=no'",
#                 "-o 'ConnectionAttempts=3'",
#                 "-o 'ConnectTimeout=25'",
#                 $source, $local_file ]);
        my $e = runEx(
            "scp -rp".
            " -o 'UserKnownHostsFile=$UserKnownHostsFile'".
            " -o 'StrictHostKeyChecking=no'".
            " -o 'ConnectionAttempts=3'".
            " -o 'ConnectTimeout=25' ".
            $self->_getMasterCmd().
            $self->_getPortScpCmd('yes').
            " $source $local_file", 0, "", $timeout );
        return $e;
    }
}

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

