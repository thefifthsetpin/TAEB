package TAEB::World::Level;
use TAEB::OO;
use TAEB::Util qw/deltas delta2vi vi2delta tile_types/;
use List::MoreUtils 'any';
use List::Util 'first';

with 'TAEB::Meta::Role::Reblessing';

use overload %TAEB::Meta::Overload::default;

has tiles => (
    isa     => 'ArrayRef[Maybe[ArrayRef[TAEB::World::Tile]]]',
    default => sub {
        my $self = shift;
        # ugly, but ok
        [ undef,

          map { my $y = $_;
            [ map {
                TAEB::World::Tile->new(level => $self, x => $_, y => $y)
            } 0 .. 79 ]
        } 1 .. 21 ]
    },
);

has dungeon => (
    isa      => 'TAEB::World::Dungeon',
    weak_ref => 1,
);

has special_level => (
    isa      => 'Str',
    is       => 'rw',
    default  => "",
    trigger  => sub {
        my $self = shift;
        my $level = ucfirst(shift);
        my $new_pkg = "TAEB::World::Level::$level";

        if ($new_pkg->can('meta')) {
            $self->rebless($new_pkg);
        }
    },
);

has branch => (
    isa       => 'TAEB::Type::Branch',
    predicate => 'known_branch',
    trigger   => sub {
        my ($self, $name) = @_;
        TAEB->log->level("$self is in branch $name!");
    },
);

has z => (
    isa => 'Int',
);

has monsters => (
    metaclass  => 'Collection::Array',
    is         => 'rw',
    isa        => 'ArrayRef[TAEB::World::Monster]',
    auto_deref => 1,
    default    => sub { [] },
    provides   => {
        push   => 'add_monster',
        clear  => 'clear_monsters',
        empty  => 'has_monsters',
        count  => 'monster_count',
    }
);

has turns_spent_on => (
    metaclass => 'Counter',
);

has pickaxe => (
    isa     => 'Int',
    default => 0,
);

has tiles_by_type => (
    isa     => 'HashRef[ArrayRef[TAEB::World::Tile]]',
    default => sub { {} },
);

has items => (
    metaclass  => 'Collection::Array',
    is         => 'ro',
    isa        => 'ArrayRef[TAEB::World::Item]',
    default    => sub { [] },
    auto_deref => 1,
    provides   => {
        count  => 'item_count',
    },
);

has fully_explored => (
    isa     => 'Bool',
    default => 0,
);

# Note that the quest portal can be on the rogue level, so this can't
# be just another special level.
has has_quest_portal => (
    isa     => 'Bool',
    default => 0,
);

has _astar_cache => (
    isa     => 'HashRef[Str]',
    lazy    => 1,
    clearer => 'clear_astar_cache',
    default => sub { {} },
);


# So, for these is_<speciallevel>,
#    true  => definitely that level
#    false => definitely not that level
#    undef => maybe that level?
#

our @special_levels = qw/minetown rogue oracle bigroom/;

for my $level (@special_levels) {
    has "is_$level" => (
        isa     => 'Bool',
        trigger => sub {
            my ($self, $is_level) = @_;
            $self->special_level($level) if $is_level;
            TAEB->log->level(
                sprintf('This level is most definitely%s %s.',
                        $is_level ? '' : ' not',
                        ucfirst($level)
                ),
            );
        },
    );
}

sub base_class { __PACKAGE__ }

# XXX: Yes this REALLY REALLY sucks but it's an "easy" optimization
{
my $cartographer;
    sub at {
        my ($self, $x, $y) = @_;
        $cartographer = TAEB->dungeon->cartographer
            unless defined $cartographer;
        $x = $cartographer->{x} unless defined $x;
        $y = $cartographer->{y} unless defined $y;

        # XXX: reenable this if we start getting weird errors
        #if ($x < 0 || $y < 0) {
            #Carp::cluck("Level->at($x, $y) called. Stop doing that!");
            #return undef;
        #}

        return $self->{tiles}->[$y][$x];
    }
}

sub at_direction {
    my $self      = shift;
    my $x         = @_ > 2 ? shift : TAEB->x;
    my $y         = @_ > 1 ? shift : TAEB->y;
    my $direction = shift;

    my ($dx, $dy) = vi2delta($direction);

    $self->at($x + $dx, $y + $dy);
}

sub update_tile {
    my $self     = shift;
    my $x        = shift;
    my $y        = shift;
    my $newglyph = shift;
    my $color    = shift;

    $self->tiles->[$y][$x]->update($newglyph, $color);
}

sub step_on {
    my $self = shift;
    my $x = shift;
    my $y = shift;

    $self->tiles->[$y][$x]->step_on;
}

sub step_off {
    my $self = shift;
    my $x = shift;
    my $y = shift;

    $self->tiles->[$y][$x]->step_off;
}

=head2 radiate CODE[, ARGS] -> (Str | (Str, Int))

This method will radiate in the eight NetHack directions. It will call the
coderef for each tile encountered. The coderef will receive the tile as its
argument. Once the coderef returns a true value, then the radiating stops and
something will be returned:

If called in scalar context, the vi-key direction will be returned. If called
in list context, the vi-key direction and distance will be returned.

The optional arguments are:

=over 4

=item max (default: 80)

How far to radiate outwards. You probably can't throw a dagger all the way
across the level, so you may want to decrease it to something more realistic.
Like 3, har har. You're weak.

=back

=cut

sub radiate {
    my $self = shift;
    my $code = shift;
    my %args = (
        max => 80, # hey, we may want to throw all the way across the level..
        @_,
    );

    my $stopper = $args{stopper} || sub { 0 };

    # check each direction
    DIRECTION: for (deltas) {
        my ($dx, $dy) = @$_;
        my ($x, $y) = (TAEB->x, TAEB->y);

        for (1 .. $args{max}) {
            $x += $dx; $y += $dy;

            # have we fallen off the map? if so, stop this line of radiation
            my $tile = TAEB->current_level->at($x, $y) or next DIRECTION;

            next DIRECTION if $stopper->($tile);

            my $ret = $code->($tile);
            if ($ret) {
                # if they ask for a scalar, give them the direction
                return delta2vi($dx, $dy) if !wantarray;

                # if they ask for a list, give them (direction, distance, $tile)
                return (delta2vi($dx, $dy), $_, $tile);
            }

            # stop radiating
            $tile->is_walkable(1) or next DIRECTION;

        }
    }

}

sub remove_monster {
    my $self    = shift;
    my $monster = shift;

    for (my $i = 0; $i < $self->monster_count; ++$i) {
        if ($self->monsters->[$i] == $monster) {
            splice @{ $self->monsters }, $i, 1;
            return 1;
        }
    }

    TAEB->log->level("Unable to remove $monster from the current level!",
                     level => 'warning');
}

my @unregisterable = qw(unexplored rock wall floor corridor obscured);
my %is_unregisterable = map { $_ => 1 } @unregisterable;
sub is_unregisterable { $is_unregisterable{$_[1]} }

sub register_tile {
    my $self = shift;
    my $tile = shift;
    my $type = shift || $tile->type;

    push @{ $self->tiles_by_type->{$type} ||= [] }, $tile
        unless $self->is_unregisterable($type);
}

sub unregister_tile {
    my $self = shift;
    my $tile = shift;
    my $type = shift || $tile->type;

    return if $self->is_unregisterable($type);

    for (my $i = 0; $i < @{ $self->tiles_by_type->{$type} || [] }; ++$i) {
        if ($self->tiles_by_type->{$type}->[$i] == $tile) {
            splice @{ $self->tiles_by_type->{$type} }, $i, 1;
            return 1;
        }
    }

    TAEB->log->level("Unable to unregister $tile", level => 'warning');
}

sub has_type {
    my $self = shift;
    map { @{ $self->tiles_by_type->{$_} || [] } } @_
}

*tiles_of = \&has_type;

sub has_enemies { grep { $_->is_enemy } shift->monsters }

sub exits {
    my $self = shift;

    my @exits = map { $self->tiles_of($_) } qw/stairsup stairsdown/;

    @exits = grep { $_->type ne 'stairsup' } @exits
        if $self->z == 1; # XXX check for Amulet

    return @exits;
}

sub exit_towards {
    my $self = shift;
    my $other = shift;
    my $back = shift;

    return if $self == $other;

    for my $exit ($self->exits) {
        next if !$exit->other_side;

        next if defined $back && $exit->other_side->level == $back;

        return $exit if $exit->other_side->level == $other;

        my $rec = $exit->other_side->level->exit_towards($other, $self);

        return $exit if $rec;
    }

    return;
}

sub adjacent_levels {
    map  { $_->level }
    grep { defined }
    map  { $_->other_side }
    shift->exits
}

sub iterate_tile_vt {
    my $self = shift;
    my $code = shift;
    my $vt   = shift || TAEB->vt;

    for my $y (1 .. 21) {
        my @glyphs = split '', $vt->row_plaintext($y);
        my @colors = $vt->row_color($y);

        for my $x (0 .. 79) {
            return unless $code->(
                $self->at($x, $y),
                $glyphs[$x],
                $colors[$x],
                $x,
                $y,
            );
        }
    }

    return 1;
}

sub first_tile {
    my $self = shift;
    my $code = shift;

    for my $y (1 .. 21) {
        for my $x (0 .. 79) {
            my $tile = $self->at($x, $y);
            return $tile if $code->($tile);
        }
    }

    return;
}

sub matches_vt {
    my $self = shift;
    my $vt   = shift || TAEB->vt;

    $self->iterate_tile_vt(sub {
        my ($tile, $glyph, $color, $x, $y) = @_;

        # the new level has rock where we used to have something else. that's
        # a pretty clear indicator
        return 0 if $glyph eq ' '
                 && $tile->type ne 'rock'
                 && $tile->type ne 'unexplored'
                 && $tile->type ne 'floor';

        return 1;
    }, $vt);
}

my %branch = (
    dungeons => sub { shift->z < 29 },
    mines    => sub {
        my $self = shift;
        $self->z >= 3 && $self->z <= 13;
    },
);

sub detect_branch {
    my $self = shift;
    return if $self->known_branch;

    for my $name (keys %branch) {
        if ($branch{$name}->($self)) {
            my $method = "_detect_$name";
            if ($self->$method) {
                $self->branch($name);
                last;
            }
        }
    }
}

sub _detect_dungeons {
    my $self = shift;

    # out of range of the mines
    return 1 if $self->z < 3 || $self->z > 13;

    # is there a parallel mines level?
    return 1 if any { $_->known_branch && $_->branch eq 'mines' }
                $self->dungeon->get_levels($self->z);

    # dungeon features (fountain, sink, altar, door, etc)
    # watch out for minetown
    return 1 if ($self->z != 5 && $self->z != 6)
             && ($self->has_type('closeddoor')
             ||  $self->has_type('opendoor')
             ||  $self->has_type('altar')
             ||  $self->has_type('sink')
             ||  $self->has_type('fountain'));


    return 0;
}

sub _detect_mines {
    my $self = shift;

    # is there a parallel dungeons level?
    return 1 if any { $_->known_branch && $_->branch eq 'dungeons' }
                $self->dungeon->get_levels($self->z);

    # convex walls
    # - futilius has crazy schemes!
    #   + two diagonally adjacent walls of the same glyph
    #   + something that looks like:
    #         ---
    #           |
    #           ---

    # >6 or so floor tiles in a row (rooms have a max height)

    my $mines = 0;
    return 1 if $self->first_tile(sub {
        my $tile = shift;
        return 0 if $tile->type ne 'wall';

        $tile->each_diagonal(sub {
            my $t = shift;
            $mines = 1 if $t->type eq 'wall'
                       && $t->glyph eq $tile->glyph;
        });

        return $mines;
    });

    return 0;
}

my $A1_row6  = qr/                                ------  -----/;
my $A1_row11 = qr/                                |---------.---/;
my $A1_row17 = qr/                                 |..----------/;

my $B1_row6  = qr/                                -------- ------/;
my $B1_row11 = qr/                                |.|------0----\|/;
my $B1_row16 = qr/                                ----   --------/;

sub detect_sokoban_vt {
    my $self = shift;
    my $vt   = shift || TAEB->vt;

    return 1 if $vt->row_plaintext(6)  =~ $A1_row6
             && $vt->row_plaintext(11) =~ $A1_row11
             && $vt->row_plaintext(17) =~ $A1_row17;

    return 1 if $vt->row_plaintext(6)  =~ $B1_row6
             && $vt->row_plaintext(11) =~ $B1_row11
             && $vt->row_plaintext(16) =~ $B1_row16;

    return 0;
}

around is_minetown => sub {
    my $orig = shift;
    my $self = shift;

    return $self->$orig(@_) if @_;

    my $is_minetown = $self->$orig;
    return $is_minetown if defined $is_minetown;

    return unless $self->known_branch;
    unless ($self->branch eq 'mines' && $self->z >= 5 && $self->z <= 8) {
        $self->is_minetown(0);
        return 0;
    }

    return unless $self->has_type('closeddoor')
               || $self->has_type('opendoor')
               || $self->has_type('altar')
               || $self->has_type('sink')
               || $self->has_type('fountain')
               || $self->has_type('tree');

    TAEB->log->level("$self is Minetown!");
    $self->is_minetown(1);
    return 1;
};

around is_oracle => sub {
    my $orig = shift;
    my $self = shift;

    return $self->$orig(@_) if @_;

    my $is_oracle = $self->$orig;
    return $is_oracle if defined $is_oracle;

    if ($self->known_branch && $self->branch ne 'dungeons') {
        $self->is_oracle(0);
        return 0;
    }
    unless ($self->z >= 5 && $self->z <= 9) {
        $self->is_oracle(0);
        return 0;
    }

    my $oracle_tile = $self->at(39,12);
    if ($oracle_tile->has_monster) {
        my $oracle = $oracle_tile->monster->is_oracle;
        $self->is_oracle($oracle);
        return $oracle;
    }

    return 0;
};

sub detect_bigroom_vt {
    my $self = shift;

    # Bigroom 1
    # Technically also 2 + 3, but it'll take a lot of exploration,
    # so we'll need something better for those.
    return 1 if TAEB->vt->row_plaintext(4) =~ /-{75}/;

    # XXX : Find out good ways to detect 2,3,4,5. 
    #       Maps: http://nethack.wikia.com/wiki/Bigroom

    # Undef means unsure.
    return;
}

around is_bigroom => sub {
    my $orig = shift;
    my $self = shift;

    return $self->$orig(@_) if @_;

    my $is_bigroom = $self->$orig;
    return $is_bigroom if defined $is_bigroom;

    unless ($self->z >= 10 && $self->z <= 12) {
        $self->is_bigroom(0);
        return 0;
    }

    $self->branch('dungeons') if $self->$orig($self->detect_bigroom_vt);
    return $self->$orig;
};

sub each_tile {
    my $self = shift;
    my $code = shift;

    for my $y (1..21) {
        for my $x (0..79) {
            $code->($self->at($x, $y));
        }
    }
}

sub msg_dungeon_level {
    my $self = shift;
    my $level = shift;
    my $islevel = "is_$level";

    TAEB->log->level("Hey, I know this level! It's $level!")
        if !$self->$islevel;

    $self->branch('dungeons') if $level eq 'oracle'
                              || $level eq 'rogue'
                              || $level eq 'bigroom';

    $self->$islevel(1);
}

sub msg_level_message {
    my $self = shift;
    my $type = shift;

    TAEB->log->level("There's a $type on this level. Interesting.");

    $self->branch('dungeons') if $type eq 'vault';

    $self->is_minetown(1) if $type eq 'shop'
                          && $self->known_branch
                          && $self->branch eq 'mines';
}

sub msg_turn {
    my $self = shift;
    $self->inc_turns_spent_on;
}

=head2 glyph_to_type str[, str] -> str

This will look up the given glyph (and if given color) and return a tile type
for it. Note that monsters and items (and any other miss) will return
"obscured".

=cut

sub glyph_to_type {
    my $self  = shift;
    my $glyph = shift;

    return $TAEB::Util::glyphs{$glyph} || 'obscured' unless @_;
    # glyph_to_type will always return 'rock' for blank tiles
    return $TAEB::Util::glyphs{$glyph}->[0] if $glyph eq ' ';

    # use color in an effort to differentiate tiles
    my $color = shift;

    return 'obscured' unless $TAEB::Util::glyphs{$glyph}
                          && $TAEB::Util::feature_colors{$color};

    my @a = map { ref $_ ? @$_ : $_ } $TAEB::Util::glyphs{$glyph};
    my @b = map { ref $_ ? @$_ : $_ } $TAEB::Util::feature_colors{$color};

    # calculate intersection of the two lists
    # because of the config chosen, given a valid glyph+color combo
    # we are guaranteed to only have one result
    # an invalid combination should not return any
    my %intersect;
    $intersect{$_} |= 1 for @a;
    $intersect{$_} |= 2 for @b;

   my $type = first { $intersect{$_} == 3 } keys %intersect;
   return $type || 'obscured';
}

=head2 glyph_is_monster str -> bool

Returns whether the given glyph is that of a monster.

=cut

sub glyph_is_monster {
    my $self = shift;
    return shift =~ /[a-zA-Z&';:1-5@]/;
}

=head2 glyph_is_item str -> bool

Returns whether the given glyph is that of an item.

=cut

sub glyph_is_item {
    my $self = shift;
    return shift =~ /[`?!%*()+=\["\$\/]/;
}


sub msg_farlooked {
    my $self = shift;
    my $tile = shift;
    my $msg  = shift;

    $tile->farlooked($msg);
}

sub msg_tile_update {
    my $self = shift;
    $self->fully_explored(0);
    $self->clear_astar_cache;
}

sub reblessed {
    my $self = shift;
    $self->dungeon->special_level->{ $self->special_level } = $self;
}

sub debug_line {
    my $self = shift;
    my $branch = $self->branch || '???';
    sprintf "branch=%s, dlvl=%d", $branch, $self->z;
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;

