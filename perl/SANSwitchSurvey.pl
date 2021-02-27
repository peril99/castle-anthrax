
package SANSwitch;

# This module interacts with a series of brocade switches, and outputs
# zoning and confiuration information for tracking.
# This is intended to monitor changes in configuration, 
# as well as provide configuration history of an important piece of 
# infrastructure, (Brocade SAN Switches)
#

use strict;
use warnings;

use Exporter;
use Expect;
use Data::Dumper;

our @ISA    = qw(Exporter);
our @EXPORT = qw(new getconfig dumpzone dumpswitch);

# Turn this on if you need to debug the Expect script interaction.

$Expect::Log_Stdout =0 ;

################################################

sub by_number() {
    $a <=> $b;
}

################################################
# return anonymos hash
sub new {

    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        switchname => shift,
        password   => shift,
    };
    bless $self, $class;
    return $self;
}

################################################
# Using the Expect.pm module, login to the switches and grab the 
# Values that we care about.
# These are the properties that we are attempting to grab.
# switchshow, nsshow, cfgshow, 
# other that may be nice to have gbicshow, supportshow, but I don't have 
# need for them yet.
###############################################
sub getconfig {

    my $self  = shift;
    my $login = Expect->spawn("telnet $self->{switchname}");

    $login->expect( 30, "in:" )
      || die "Never got login prompt on $self->{switchname}, "
      . $login->exp_error() . "\n";
    print $login "admin\r";

    $login->expect( 30, "word:" )
      || die "Never got password prompt on $self->{switchname}, "
      . $login->exp_error() . "\n";
    print $login "$self->{password}\r";

    my $out = $login->expect( 30, "\'Enter\'", "admin" )
      || die "Never got prompt back on $self->{switchname}, "
      . $login->exp_error() . "\n";
    if ( $out == 1 ) {
        print $login "\003\r";

	# Don't forget to keep the following in there, (I shunted this by accident, and 
	# got all twisted up in incorrect $login->exp_before() mischief.
        $login->expect( 30, "admin" )
          || die "Never got admin prompt on $self->{switchname}, "
          . $login->exp_error() . "\n";
    }

    print $login "switchshow\r";
    $login->expect( 30, "admin" )
      || die "Never got admin prompt on $self->{switchname}, "
      . $login->exp_error() . "\n";
    $self->{switchshow} = $login->exp_before();

    print $login "nsshow\r";
    $login->expect( 30, "admin" )
      || die "Never got admin prompt on $self->{switchname}, "
      . $login->exp_error() . "\n";
    $self->{nsshow} = $login->exp_before();

    print $login "cfgshow\r";
    $login->expect( 30, "admin" )
      || die "Never got admin prompt on $self->{switchname}, "
      . $login->exp_error() . "\n";
    $self->{cfgshow} = $login->exp_before();

    $login->close();

    # Split the switchshow output and create the %{$self->{port}}
    # 
    # 
    my @tmp = split ( /\n/, $self->{switchshow} );
    foreach my $line (@tmp) {
        if ( $line =~
            /([ 0-9][0-9]) +(id) +(N[0-9]) +(.*line) +(.*rt) +(.*[^
]).*/ )
        {

            $self->{port}->{$1}->{state}    = $4;
            $self->{port}->{$1}->{porttype} = $5;
            $self->{port}->{$1}->{wwnn}     = $6;
            $self->{port}->{$6}->{wwnn}     = $1;
        }
    }

	# Add back in the newlines before the N ports (NL too, but haven't seen one yet)
	# used tmp as the following line looked too hairy, and I feel guilty as hell for modifying
    # my output, but heck, I'm not going to use it for anything (I think)
    # This sets up the i$self->{ns} hash
    $self->{nsshow} =~ s/N/\nN/g;
    @tmp = ();
    my $i = 0;
    @tmp = split ( /\n/, $self->{nsshow} );
    foreach (@tmp) {
		/^(N|NL)\s+([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2});\s+.*[^;];(.*[^;]);(.*[^;]);/
          and do {
            $self->{ns}->{port2wwpn}->{ hex($3) } = $5;
            $self->{ns}->{wwpn2port}->{$5} = hex($3);
          }
    }

    #Make a copy of the cfg show, as we're going to end up tracking the original
    #in cvs and don't want to munge the original

    my $tmp = $self->{cfgshow};
    @tmp = ();
    $tmp =~ s/\n//g;
    $tmp =~ s/
//g;
    $tmp =~ s/(Defined)/\n$1/g;
    $tmp =~ s/(Effective)/\n$1/g;
    $tmp =~ s/(zone:)/\n$1/g;
    $tmp =~ s/(alias:)/\n$1/g;
    @tmp = split ( /\n/, $tmp );

    foreach (@tmp) {

        # Set the Effective configuration
        # Not going crazy here, as I'm not looking to deal with 
        # sets of configs here, only looking to deal with the zones.

        /(Effective configuration: cfg:)\s+(.*)/ and do {
            $self->{effective} = $2;
        };

        # setup the alias hash, (for use in dereferencing the zone hash)
        # memory is cheap ;)

        /^(alias).*?:.*?\D(.*)?\s\s+(.*)/ and do {
            my $a = $3;
            my $b = $2;
            $b =~ s/\s//g;
            $a =~ s/\s//g;
            $self->{alias}->{$a} = $b;
            $self->{alias}->{$b} = $a;
        };

        # chop out the zone with names! 
        # points to the hash of the 
        # name of the zone, and then the list of thingies within that zone.
        # I think this needs to be regexed to not have the \;'s at the end

        /^(zone).*?:.*?\D(.*)?(;.*)/ and do {
            $tmp = $2 . $3;
            $tmp =~ s/;//g;
            my @a = split ( /\s+/, $tmp );
            $i = shift @a;
            $self->{zone}->{$i} = [@a];
        };

    }

};

################################################
sub dumpzone() {
    my $self = shift;
    foreach my $r ( keys %{ $self->{zone} } ) {
        print $r. "\n";
        foreach my $i ( sort @{ $self->{zone}->{$r} } ) {
            print "\t$i";
            print "\t";
            print $self->{alias}->{$i};
            print "\t";
            if ($self->{ns}->{wwpn2port}->{ $self->{alias}->{$i} }){
				print $self->{ns}->{wwpn2port}->{ $self->{alias}->{$i} };
			} else { print "undefined";}
            print "\n";
        }
    }

}
################################################
sub dumpswitch() {
    my $self = shift;
	print $self->{switchname}."\n";
	print "portname\twwpn\talias\n";
    foreach my $r ( sort by_number keys %{ $self->{ns}->{port2wwpn} } ) {
        print "$r\t$self->{ns}->{port2wwpn}->{$r}\t$self->{alias}->{$self->{ns}->{port2wwpn}->{$r}}\n";
        }
    }
################################################

1;
