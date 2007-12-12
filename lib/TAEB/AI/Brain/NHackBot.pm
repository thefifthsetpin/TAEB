#!/usr/bin/env perl
package TAEB::AI::Brain::NHackBot;
use Moose;
extends 'TAEB::AI::Brain';

=head1 NAME

TAEB::AI::Brain::NHackBot - Know thy roots

=cut

sub next_action {
    my $self = shift;
    my $taeb = shift;

    my $fight;

    $self->each_adjacent(sub {
        my (undef, $taeb, $tile, $dir) = @_;
        if ($tile->has_monster) {
            $taeb->info("Avast! I see a ".$tile->glyph." monster in the $dir direction.");
            $fight = $dir;
        }
    });

    return $fight
        if $fight;

    # kick down doors
    $self->each_adjacent(sub {
        my (undef, $taeb, $tile, $dir) = @_;
        if ($tile->type eq 'door' && $tile->floor_glyph eq ']') {
            $taeb->info("Oh dear! I see a wood board monster in the $dir direction.");
            $fight = chr(4) . $dir;
        }
    });

    return $fight
        if $fight;

    # track down monsters
    my ($to, $path) = TAEB::World::Path->first_match_level(
        $taeb->current_tile,
        sub { shift->has_monster },
    );

    if ($path) {
        $taeb->info("I've got a bone to pick with a " . $to->glyph . "! $path");
        return substr($path, 0, 1);
    }

    # explore
    ($to, $path) = TAEB::World::Path->first_match_level(
        $taeb->current_tile,
        sub {
            my ($tile, $path) = @_;
            return $tile->stepped_on == 0 && length $path;
        },
    );

    if ($path) {
        $taeb->info("Exploring! $path");
        return substr($path, 0, 1);
    }

    # search
    ($to, $path) = TAEB::World::Path->max_match_level(
        $taeb->current_tile,
        sub {
            my ($tile, $path) = @_;
            return undef if $tile->type ne 'wall';
            return 1 / (($tile->searched + length $path) || 1);
        },
    );

    if ($path) {
        $taeb->info("Searching! $path");
        return substr($path, 0, 1);
    }

    $taeb->current_tile->each_neighbor(sub {
        my $self = shift;
        $self->searched($self->searched + 1);
    });

    return 's';
}

