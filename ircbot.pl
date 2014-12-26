#!/usr/bin/perl

use strict;
use warnings;

use POE;
use POE::Component::IRC;
use POE::Component::IRC::Plugin::Connector;
use Switch;
use JSON::XS;

my $config_file = "ircbot.conf";
my $datadir="data";
my $item_key_file="$datadir/item_keys.json";

### default configuration parameters
my $config = {};
$config->{channel} = "#zabbix";
$config->{curl_flags} = "";
$config->{jira_host} = "https://support.zabbix.com";
$config->{nick} = "zabbix";
$config->{port} = "6667";
$config->{real} = "Zabbix IRC Bot";
$config->{server} = "irc.freenode.net";
$config->{user} = "zabbix";

### read configuration
if (open (my $fh, '<:raw', $config_file)) {
    my $configcontents; { local $/; $configcontents = <$fh>; }
    # if present in the JSON structure, will override parameters that were defined above
    close $fh;
    my $config_read = decode_json($configcontents);
    @$config{keys %$config_read} = values %$config_read;
}

### read item keys
open (my $fh, '<:raw', $item_key_file) or die "Can't open $item_key_file";
my $itemkeycontents; { local $/; $itemkeycontents = <$fh>; }
close $fh;
my $itemkeys_read = decode_json($itemkeycontents);

my ($irc) = POE::Component::IRC->spawn();

### helper functions

sub reply
{
    $irc->yield(privmsg => $config->{channel}, $_[0]);
}

### public interface

my %COMMANDS =
(
    help  => { function => \&cmd_help,  usage => 'help <command> - print usage information'   },
    issue => { function => \&cmd_issue, usage => 'issue <n|jira> - fetch issue description'   },
    key   => { function => \&cmd_key,   usage => 'key <item key> - show item key description' },
);

my @ignored_commands = qw (note quote);

sub get_command
{
    my @commands = ();

    foreach my $command (keys %COMMANDS)
    {
        push @commands, $command if $command =~ m/^$_[0]/;
    }

    return join ', ', sort @commands;
}

sub get_itemkey
{
    my @itemkeys = ();
    foreach my $itemkey (keys $itemkeys_read)
    {
        push @itemkeys, $itemkey if $itemkey =~ m/^$_[0]/;
    }

    return join ', ', sort @itemkeys;
}

sub cmd_help
{
    if (@_)
    {
        my $command = get_command $_[0];

        switch ($command)
        {
            case ''   { reply "ERROR: Command \"$_[0]\" does not exist.";                          }
            case /, / { reply "ERROR: Command \"$_[0]\" is ambiguous (candidates are: $command)."; }
            else      { reply $COMMANDS{$command}->{usage};                                        }
        }
    }
    else
    {
        reply 'Available commands: ' . (join ', ', sort keys %COMMANDS) . '.';
        reply 'Type "!help <command>" to print usage information for a particular command.';
    }
}

sub cmd_key
{
    if (@_)
    {
        my $itemkey = get_itemkey $_[0];

        switch ($itemkey)
        {
            case ''   { reply "ERROR: Item key \"$_[0]\" not known.";                                  }
            case /, / { reply "ERROR: Multiple item keys match \"$_[0]\" (candidates are: $itemkey)."; }
            else      { reply "$itemkey: $itemkeys_read->{$itemkey}";                                  }
        }
    }
    else
    {
        reply 'Type "!itemkey <item key>" to see item key description.';
    }
}

my @issues = ();
my %issues = ();

sub get_issue
{
    return $issues{$_[0]} if exists $issues{$_[0]};

    my $json = `curl --silent $config->{curl_flags} $config->{jira_host}/rest/api/2/issue/$_[0]?fields=summary` or return "ERROR: Could not fetch issue description.";

    if (my ($descr) = $json =~ m!summary":"(.+)"}!)
    {
        $descr =~ s/\\([\\"])/$1/g;
        return +($issues{$_[0]} = "[$_[0]] $descr (URL: https://support.zabbix.com/browse/$_[0])");
    }
    else
    {
        my ($error) = $json =~ m!errorMessages":\["(.+)"\]!;
        $error = 'unknown' unless $error;
        $error = lc $error;

        return "ERROR: Could not fetch issue description. Reason: $error.";
    }
}

sub cmd_issue
{
    @_ = ('1') if not @_;
    my $issue = uc $_[0];

    if ($issue =~ m/^\d+$/)
    {
        reply +($issue - 1 <= $#issues ? get_issue($issues[-$issue]) : "ERROR: Issue \"$issue\" does not exist in chat history.");
    }
    elsif ($issue =~ m/^\w{3,7}-\d{1,4}$/)
    {
        reply get_issue($issue);
    }
    else
    {
        reply "ERROR: Argument \"$_[0]\" is not a number or an issue identifier.";
    }
}

### event handlers

sub on_start
{
    $irc->yield(register => 'all');

    $_[HEAP]->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add('Connector' => $_[HEAP]->{connector});

    $irc->yield
    (
        connect =>
        {
            Nick     => $config->{nick},
            Username => $config->{user},
            Ircname  => $config->{real},
            Server   => $config->{server},
            Port     => $config->{port},
        }
    );
}

sub on_connected
{
    $irc->yield(join => $config->{channel});
}

sub on_public
{
    my ($who, $where, $message) = @_[ARG0, ARG1, ARG2];

    my $nick = (split /!/, $who)[0];
    my $channel = $where->[0];
    my $timestamp = localtime;

    print "[$timestamp] $channel <$nick> $message\n";

    if (my ($prefix, $argument) = $message =~ m/^!(\w+)\b(.*)/g)
    {
        if (grep { /^$prefix$/ } @ignored_commands) { return };
        my $command = get_command $prefix;
        $argument =~ s/^\s+|\s+$//g if $argument;

        switch ($command)
        {
            case ''   { reply "ERROR: Command \"$prefix\" does not exist.";                                         }
            case /, / { reply "ERROR: Command \"$prefix\" is ambiguous (candidates are: $command).";                }
            else      { $argument ? $COMMANDS{$command}->{function}($argument) : $COMMANDS{$command}->{function}(); }
        }
    }
    else
    {
        push @issues, map {uc} ($message =~ m/\b(\w{3,7}-\d{1,4})\b/g);
        @issues = @issues[-15 .. -1] if $#issues >= 15;
    }
}

sub on_default
{
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ();

    return if $event eq '_child';

    foreach (@$args)
    {
        if (ref $_ eq 'ARRAY')
        {
            push @output, '[', join(', ', @$_), ']';
            last;
        }
        if (ref $_ eq 'HASH')
        {
            push @output, '{', join(', ', %$_), '}';
            last;
        }
        push @output, "\"$_\"";
    }

    printf "[%s] unhandled event '%s' with arguments <%s>\n", scalar localtime, $event, join ' ', @output;
}

sub on_ignored
{
    # ignore event
}

### connect to IRC

POE::Session->create
(
    inline_states =>
    {
        _default         => \&on_default,
        _start           => \&on_start,
        irc_001          => \&on_connected,
        irc_public       => \&on_public,
        irc_ctcp_action  => \&on_public,

        map { ; "irc_$_" => \&on_ignored }
            qw(connected isupport join mode notice part ping registered quit
               002 003 004 005 251 254 255 265 266 332 333 353 366 422 451)
    }
);

$poe_kernel->run();

exit 0;
