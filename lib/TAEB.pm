#!perl
package TAEB;
use Curses ();

use TAEB::Util ':colors';

use Moose;
use MooseX::AttributeHelpers;
use MooseX::ClassAttribute;

use Log::Dispatch;
use Log::Dispatch::File;

use TAEB::Meta::Types;
use TAEB::Meta::Overload;
use TAEB::Config;
use TAEB::VT;
use TAEB::ScreenScraper;
use TAEB::Spoilers;
use TAEB::Knowledge;
use TAEB::World;
use TAEB::Senses;
use TAEB::Action;
use TAEB::Publisher;

=head1 NAME

TAEB - Tactical Amulet Extraction Bot

=cut

# report errors to the screen? should only be done while playing NetHack, not
# during REPL or testing
our $ToScreen = 0;

class_has interface => (
    is       => 'rw',
    isa      => 'TAEB::Interface',
    handles  => [qw/read write/],
    lazy     => 1,
    default  => sub {
        use TAEB::Interface::Local;
        TAEB::Interface::Local->new;
    },
);

class_has personality => (
    is       => 'rw',
    isa      => 'TAEB::AI::Personality',
    lazy     => 1,
    default  => sub {
        use TAEB::AI::Personality::Human;
        return TAEB::AI::Personality::Human->new;
    },
    handles  => [qw(want_item currently next_action)],
    trigger  => sub {
        my ($self, $personality) = @_;
        TAEB->info("Now using personality $personality.");
        $personality->institute;
    },
);

class_has scraper => (
    is       => 'rw',
    isa      => 'TAEB::ScreenScraper',
    lazy     => 1,
    default  => sub { TAEB::ScreenScraper->new },
    handles  => [qw(parsed_messages all_messages messages farlook)],
);

class_has config => (
    is       => 'rw',
    isa      => 'TAEB::Config',
    lazy     => 1,
    default  => sub { TAEB::Config->new },
);

class_has vt => (
    is       => 'rw',
    isa      => 'TAEB::VT',
    lazy     => 1,
    default  => sub {
        my $vt = TAEB::VT->new(cols => 80, rows => 24);
        $vt->option_set(LINEWRAP => 1);
        $vt->option_set(LFTOCRLF => 1);
        return $vt;
    },
    handles  => [qw(topline)],
);

class_has state => (
    is      => 'rw',
    isa     => 'PlayState',
    default => 'logging_in',
);

class_has log => (
    is      => 'ro',
    isa     => 'Log::Dispatch',
    lazy    => 1,
    handles => [qw(debug info warning error critical)],
    default => sub {
        my $format = sub {
            my %args = @_;
            chomp $args{message};
            return "[\U$args{level}\E] ".localtime().": $args{message}\n";
        };

        my $dispatcher = Log::Dispatch->new(callbacks => $format);
        for (qw(debug info warning error critical)) {
            $dispatcher->add(
                Log::Dispatch::File->new(
                    name => $_,
                    min_level => $_,
                    filename => "log/$_.log",
                )
            );
        }
        return $dispatcher;
    },
);


class_has dungeon => (
    is      => 'ro',
    isa     => 'TAEB::World::Dungeon',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return TAEB::World::Dungeon->new if $self->new_game || !TAEB->has_dump;
        return delete $self->persistent_dump->{dungeon};
    },
    handles => sub {
        my ($attr, $dungeon) = @_;

        my %delegate = map { $_ => $_ }
                       qw{current_level current_tile nearest_level
                          map_like x y z};

        for (map { $_->{name} } $dungeon->compute_all_applicable_methods) {
            $delegate{$_} = $_
                if m{
                    ^
                    (?: each | any | all | grep ) _
                    (?: orthogonal | diagonal | adjacent )
                    (?: _inclusive )?
                    $
                }x;
        }

        return %delegate;
    },
);

class_has single_step => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

class_has info_to_screen => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
);

class_has senses => (
    is      => 'rw',
    isa     => 'TAEB::Senses',
    default => sub {
        my $self = shift;
        return TAEB::Senses->new if $self->new_game || !TAEB->has_dump;
        return delete $self->persistent_dump->{senses};
    },
    lazy    => 1,
    handles => qr/^(?!_check_|msg_|update)/,
);

class_has inventory => (
    is      => 'rw',
    isa     => 'TAEB::World::Inventory',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return TAEB::World::Inventory->new if $self->new_game || !TAEB->has_dump;
        return delete $self->persistent_dump->{inventory};
    },
    handles => {
        find_item => 'find',
    },
);

class_has spells => (
    is      => 'rw',
    isa     => 'TAEB::World::Spells',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return TAEB::World::Spells->new if $self->new_game || !TAEB->has_dump;
        return delete $self->persistent_dump->{spells};
    },
    handles => {
        find_spell    => 'find',
        find_castable => 'find_castable',
        knows_spell   => 'knows_spell',
    },
);

class_has publisher => (
    is      => 'rw',
    isa     => 'TAEB::Publisher',
    lazy    => 1,
    default => sub { TAEB::Publisher->new },
    handles => [qw/enqueue_message get_exceptional_response get_response send_at_turn send_in_turns remove_messages menu_select single_select/],
);

class_has action => (
    is        => 'rw',
    isa       => 'TAEB::Action',
    predicate => 'has_action',
);

class_has knowledge => (
    is      => 'rw',
    isa     => 'TAEB::Knowledge',
    lazy    => 1,
    default => sub {
        my $self = shift;
        return TAEB::Knowledge->new if $self->new_game || !TAEB->has_dump;
        return delete $self->persistent_dump->{knowledge};
    },
);

class_has new_game => (
    is      => 'rw',
    isa     => 'Maybe[Bool]',
    default => undef,
);

class_has persistent_dump => (
    is   => 'rw',
    lazy => 1,
    default => sub {
        return unless -r TAEB->config->state_file;

        my $self = shift;
        $self->notify("Loading state file...", 0);

        local $SIG{__DIE__};

        my $dump = eval {
            use YAML::Syck;
            YAML::Syck::LoadFile(TAEB->config->state_file)
        } || undef;

        $self->redraw;
        TAEB->warning("Unable to load state file.") if !defined($dump);
        return $dump;
    },
);

class_has pathfinds => (
    is  => 'rw',
    isa => 'Int',
    default => 0,
);

=head2 iterate

This will perform one input/output iteration of TAEB.

It will return any input it receives, so you can follow along at home.

=cut

sub iterate {
    my $self = shift;

    TAEB->debug("Starting a new step.");

    $self->full_input(1);
    $self->human_input;

    my $method = "handle_" . $self->state;
    $self->$method;
}

sub handle_playing {
    my $self = shift;

    if ($self->action && !$self->action->aborted) {
        $self->action->done;
        $self->publisher->send_messages;
    }

    $self->currently('?');
    $self->pathfinds(0);
    $self->action($self->next_action);
    TAEB->info("Current action: " . $self->action);
    $self->write($self->action->run);
}

sub handle_logging_in {
    my $self = shift;

    if ($self->vt->contains("Shall I pick a character's ")) {
        TAEB->info("We are now in NetHack, starting a new character.");
        $self->write('n');
    }
    elsif ($self->topline =~ qr/Choosing Character's Role/) {
        $self->write($self->config->get_role);
    }
    elsif ($self->topline =~ qr/Choosing Race/) {
        $self->write($self->config->get_race);
    }
    elsif ($self->topline =~ qr/Choosing Gender/) {
        $self->write($self->config->get_gender);
    }
    elsif ($self->topline =~ qr/Choosing Alignment/) {
        $self->write($self->config->get_alignment);
    }
    elsif ($self->topline =~ qr/Restoring save file\.\./) {
        $self->info("We are now in NetHack, restoring a save file.");
        $self->write(' ');
        $self->new_game(0);
    }
    elsif ($self->topline =~ qr/, welcome( back)? to NetHack!/) {
        $self->new_game($1 ? 0 : 1);
        $self->enqueue_message('check');
        $self->enqueue_message('game_started');
        $self->state('playing');
    }
    elsif ($self->topline =~ /^\s*It is written in the Book of /) {
        TAEB->error("Using etc/TAEB.nethackrc is MANDATORY");
        $self->write("     \e     #quit\ny         ");
        die "Using etc/TAEB.nethackrc is MANDATORY";
    }
}

sub handle_saving {
    my $self = shift;

    $self->dump;
    $self->write("\e\eS");
}

=head2 full_input

Run a full input loop, sending messages, updating the screen, and so on.

=cut

sub full_input {
    my $self = shift;
    my $main_call = shift;

    $self->scraper->clear;

    $self->process_input;

    unless ($self->state eq 'logging_in') {
        $self->action->post_responses
            if $main_call && $self->action && !$self->action->aborted;

        $self->dungeon->update($main_call);
        $self->senses->update($main_call);
        $self->publisher->update($main_call);

        $self->redraw;
        $self->display_topline;
    }
}

=head2 process_input [Bool]

This will read the interface for input, update the VT object, and print.

It will also return any input it receives.

If the passed in boolean is false, no scraping will occur. If no boolean is
provided, or if the boolean is true, then the scraping will go down.

=cut

sub process_input {
    my $self = shift;
    my $scrape = @_ ? shift : 1;

    my $input = $self->read;

    $self->vt->process($input);

    $self->scraper->scrape
        if $scrape && $self->state ne 'logging_in';

    return $input;
}

sub human_input {
    my $self = shift;

    my $c = $self->single_step ? $self->get_key : $self->try_key
        unless Scalar::Util::blessed($self->personality) =~ /\bHuman\b/;

    if (defined $c) {
        my $out = $self->keypress($c);
        if (defined $out) {
            $self->notify($out);
        }
    }
}

=head2 keypress Str

This accepts a key (such as one typed by the meatbag at the terminal) and does
something with it.

=cut
sub keypress {
    my $self = shift;
    my $c = shift;

    # refresh modules
    if ($c eq 'r') {
        return "Module::Refresh is broken. Sorry.";
    }

    # pause for a key
    if ($c eq 'p') {
        TAEB->notify("Paused.", 0);
        TAEB->get_key;
        TAEB->redraw;
        return undef;
    }

    # turn on/off step mode
    if ($c eq 's') {
        $self->single_step(not $self->single_step);
        return "Single step mode "
             . ($self->single_step ? "enabled." : "disabled.");
    }

    if ($c eq 'd') {
        my @drawmodes = qw/normal debug pathfind/;
        for (0 .. $#drawmodes) {
            if ($self->config->draw eq $drawmodes[$_]) {
                $self->config->draw($drawmodes[($_+1) % @drawmodes]);
                return undef;
            }
        }

        $self->config->draw('normal');
        return undef;
    }

    if ($c eq 'f') {
        if ($self->config->display_method eq 'floor')
        {
            $self->config->display_method('glyph');
            return "Changing display method back to glyph.";
        }
        else {
            $self->config->display_method('floor');
            return "Changing display method to floor.";
        }
        return undef;
    }

    # turn on/off info to screen
    if ($c eq 'i') {
        $self->info_to_screen(!$self->info_to_screen);
        return "Info to screen " . ($self->info_to_screen ? "on." : "off.");
    }

    # user input (for emergencies only)
    if ($c eq "\e") {
        $self->write($self->get_key);
        return undef;
    }

    # refresh NetHack's screen
    if ($c eq "\cr") {
        # back to normal
        Curses::clear;
        Curses::refresh;
        TAEB->redraw;
        return undef;
    }

    # console
    if ($c eq '~') {
        $self->console;

        return;
    }

    if ($c eq 'q') {
        $self->state('saving');
        return "Bye bye then.";
    }

    if ($c eq 'Q') {
        $self->write("\e\e#quit\ny");
        return "Until we meet again, then.";
    }

    if ($c eq ';') {
        my ($z, $y, $x) = (TAEB->z, TAEB->y, TAEB->x);
        while (1) {
            my $tile = TAEB->current_level->at($x, $y);

            Curses::move(0, 0);
            # draw some info about the tile at the top
            Curses::addstr($tile->debug_line);
            Curses::clrtoeol;
            $self->place_cursor($x, $y);

            # where to next?
            my $c = $self->get_key;

               if ($c eq 'h') { --$x }
            elsif ($c eq 'j') { ++$y }
            elsif ($c eq 'k') { --$y }
            elsif ($c eq 'l') { ++$x }
            elsif ($c eq 'y') { --$x; --$y }
            elsif ($c eq 'u') { ++$x; --$y }
            elsif ($c eq 'b') { --$x; ++$y }
            elsif ($c eq 'n') { ++$x; ++$y }
            elsif ($c eq 'H') { $x -= 8 }
            elsif ($c eq 'J') { $y += 8 }
            elsif ($c eq 'K') { $y -= 8 }
            elsif ($c eq 'L') { $x += 8 }
            elsif ($c eq 'Y') { $x -= 8; $y -= 8 }
            elsif ($c eq 'U') { $x += 8; $y -= 8 }
            elsif ($c eq 'B') { $x -= 8; $y += 8 }
            elsif ($c eq 'N') { $x += 8; $y += 8 }
            elsif ($c eq '<' || $c eq '>') {
                $c eq '<' ? --$z : ++$z;
                # XXX: redraw screen, change current_level, etc
            }
            elsif ($c eq ';' || $c eq '.' || $c eq "\e"
                || $c eq "\n" || $c eq ' ' || $c eq 'q' || $c eq 'Q') {
                last;
            }

            $x %= 80;
            $y = ($y-1)%21+1;
        }

        # back to normal
        TAEB->redraw;
        return;
    }

    # space is always a noncommand
    return if $c eq ' ';

    return "Unknown command '$c'";
}

after qw/info warning/ => sub {
    my ($logger, $message) = @_;

    if (TAEB->info_to_screen && $TAEB::ToScreen) {
        TAEB->notify($message);
    }
};

# don't squelch warnings entirely during tests
after warning => sub {
    my ($logger, $message) = @_;

    if (!$TAEB::ToScreen) {
        local $SIG{__WARN__};
        warn $message;
    }
};

# we want stack traces for errors and crits
around qw/error critical/ => sub {
    my $orig = shift;
    my ($logger, $message) = @_;

    $logger->$orig(Carp::longmess($message));
};

after qw/error critical/ => sub {
    my ($logger, $message) = @_;

    if ($TAEB::ToScreen) {
        TAEB->complain(Carp::shortmess($message));
    }
    else {
        confess $message;
    }
};

sub _notify {
    my $self  = shift;
    my $msg   = shift;
    my $attr  = shift;
    my $sleep = @_ ? shift : 3;

    return if !defined($msg) || !length($msg);

    Curses::move(1, 0);
    Curses::attron($attr);
    Curses::addstr($msg);
    Curses::attroff($attr);
    Curses::clrtoeol;

    # using TAEB->x and TAEB->y here could screw up horrifically if the dungeon
    # object isn't loaded yet, and loading it calls notify..
    $self->place_cursor(TAEB->vt->x, TAEB->vt->y);

    return if $sleep == 0;

    Curses::refresh;
    sleep $sleep;
    $self->redraw;
}

sub notify {
    my $self = shift;
    my $msg  = shift;

    $self->_notify($msg, Curses::COLOR_PAIR(TAEB::Util::COLOR_CYAN), @_);
}

sub complain {
    my $self = shift;
    my $msg  = shift;
    $self->_notify($msg, Curses::COLOR_PAIR(TAEB::Util::COLOR_RED), @_);
}

around write => sub {
    my $orig = shift;
    my $self = shift;
    my $text = shift;

    return if length($text) == 0;

    $self->debug("Sending '$text' to NetHack.");
    $orig->($self, $text);
};

# allow the user to say TAEB->personality("human") and have it DTRT
around personality => sub {
    my $orig = shift;
    my $self = shift;

    if (@_ && (my $personality = $self->personality)) {
        $personality->deinstitute;
    }

    if (@_ && $_[0] =~ /^\w+$/) {
        my $name = shift;

        # guess the case unless they tell us what it is (because of ScoreWhore)
        $name = "\L\u$name" if $name eq lc $name;

        $name = "TAEB::AI::Personality::$name";

        (my $file = "$name.pm") =~ s{::}{/}g;
        require $file;

        return $self->$orig($name->new);
    }

    return $self->$orig(@_);
};

sub new_item {
    my $self = shift;
    TAEB::World::Item->new_item(@_);
}

sub new_monster {
    my $self = shift;
    TAEB::World::Monster->new(@_);
}

sub console {
    my $self = shift;

    eval {
        local $SIG{__DIE__};

        $ENV{PERL_RL} ||= TAEB->config->readline;

        Curses::def_prog_mode();
        Curses::endwin();

        print "\n"
            . "\e[1;37m+"
            . "\e[1;30m" . ('-' x 50)
            . "\e[1;37m[ "
            . "\e[1;36mT\e[0;36mAEB \e[1;36mC\e[0;36monsole"
            . " \e[1;37m]"
            . "\e[1;30m" . ('-' x 12)
            . "\e[1;37m+"
            . "\e[m\n";

        no warnings 'redefine';
        require Devel::REPL::Script;
        local $TAEB::ToScreen;
        Devel::REPL::Script->new->run;
    };

    Curses::clear();
    $self->redraw;
    Curses::refresh();
}

sub dump {
    return 0 unless TAEB->config->state_file;

    my $self = shift->instance;
    my %temp;
    my @stash = qw/interface config vt scraper personality action publisher state log single_step new_game persistent_dump/;

    my $state_file = TAEB->config->state_file;

    $self->notify("Creating state file...", 0);

    @temp{@stash} = delete @$self{@stash};

    eval {
        use YAML::Syck;
        YAML::Syck::DumpFile($state_file => $self)
    };

    warn $@ if $@;
    @$self{@stash} = @temp{@stash};

    $self->redraw;

    return $@ ? 0 : 1;
}

sub has_dump {
    return 0 unless TAEB->config->state_file;
    return 0 unless TAEB->persistent_dump;
    return 1;
}

sub get_key { Curses::getch }

sub try_key {
    my $self = shift;

    Curses::nodelay(Curses::stdscr, 1);
    my $c = Curses::getch;
    Curses::nodelay(Curses::stdscr, 0);

    return undef if $c eq -1;
    return $c;
}

sub redraw {
    my $self   = shift;
    my $level  = TAEB->current_level;
    my $draw   = 'draw_'.(TAEB->config->draw || 'normal');
    my $method = 'display_'.(TAEB->config->display_method || 'glyph');

    for my $y (1 .. 21) {
        Curses::move($y, 0);
        for my $x (0 .. 79) {
            $level->at($x, $y)->$draw($method);
        }
    }

    $self->draw_botl;
    $self->place_cursor;
    Curses::refresh;
}

sub draw_botl {
    my $self = shift;
    return unless $self->state eq 'playing';

    Curses::move(22, 0);

    my $command = $self->action ? $self->action->command : '?';
    $command =~ s/\n/\\n/g;
    $command =~ s/\e/\\e/g;
    $command =~ s/\cd/^D/g;

    my $currently = $self->checking
                  ? "Checking " . $self->checking
                  : $self->currently . " ($command)";
    Curses::addstr($currently);

    Curses::clrtoeol;
    Curses::move(23, 0);

    my @pieces;
    push @pieces, 'D:' . $self->current_level->z;
    $pieces[-1] .= uc substr($self->current_level->branch, 0, 1)
        if $self->current_level->branch;
    $pieces[-1] .= ' ('. ucfirst($self->current_level->special_level) .')'
        if $self->current_level->special_level;

    push @pieces, 'H:' . $self->hp;
    $pieces[-1] .= '/' . $self->maxhp
        if $self->hp != $self->maxhp;

    if ($self->spells->has_spells) {
        push @pieces, 'P:' . $self->power;
        $pieces[-1] .= '/' . $self->maxpower
            if $self->power != $self->maxpower;
    }

    push @pieces, 'A:' . $self->ac;
    push @pieces, 'X:' . $self->level;
    push @pieces, 'N:' . $self->nutrition;
    push @pieces, 'T:' . $self->turn;
    push @pieces, 'S:' . $self->score
        if $self->score;
    push @pieces, 'P:' . $self->pathfinds;

    my $status;
    for my $effect (grep { /^is_/ } $self->senses->meta->get_attribute_list) {
        if ($self->senses->$effect && $effect =~ /^is_(\w\w)/) {
            $status .= ucfirst $1;
        }
    }
    push @pieces, '[' . $status . ']'
        if $status;

    Curses::addstr(join ' ', @pieces);
    Curses::clrtoeol;
}

sub place_cursor {
    my $self = shift;
    my $x    = shift || TAEB->x;
    my $y    = shift || TAEB->y;

    Curses::move($y, $x);
}

sub display_topline {
    my $self = shift;
    my @messages = $self->parsed_messages;

    if (@messages == 0) {
        # we don't need to worry about the other rows, the map will
        # overwrite them
        Curses::move 0, 0;
        Curses::clrtoeol;
        $self->place_cursor;
        return;
    }

    while (my @msgs = splice @messages, 0, 20) {
        my $y = 0;
        for (@msgs) {
            my ($line, $matched) = @$_;

            if (TAEB->config->spicy
            &&  TAEB->config->spicy ne 'hold back on the chili, please') {
                my @spice = (
                    'rope golem',                'rape golem',             0.2,
                    'oil lamp',                  'Garin',                  0.5,
                    '\bhit',                     'roundhouse-kick',        0.02,
                    'snoring snakes',            'Eidolos taking a nap',   1,
                    'hear a strange wind',   'smell Eidolos passing wind', 1,
                    qr/(?:jackal|wolf) howling/, 'Eidolos howling',        1,
                );

                while (my ($orig, $sub, $prob) = splice @spice, 0, 3) {
                    $line =~ s/$orig/$sub/ if rand() < $prob;
                }
            }

            my $chopped = length($line) > 75;
            $line = substr($line, 0, 75);

            Curses::move $y++, 0;

            my $color = $matched
                      ? Curses::COLOR_PAIR(COLOR_GREEN)
                      : Curses::COLOR_PAIR(COLOR_BROWN);

            Curses::attron($color);
            Curses::addstr($line);
            Curses::attroff($color);

            Curses::addstr '...' if $chopped;

            Curses::clrtoeol;
        }

        if (@msgs > 1) {
            $self->place_cursor;
            Curses::refresh;
            #sleep 1;
            #sleep 2 if @msgs > 5;
            TAEB->redraw if @messages;
        }
    }
    $self->place_cursor;
}

__PACKAGE__->meta()->make_immutable();
# XXX: docs say this is required, but MX::ClassAttribute has no function
# 'containing_class'...
#MooseX::ClassAttribute::containing_class()->meta()->make_immutable();
no Moose;
no MooseX::ClassAttribute;

1;

