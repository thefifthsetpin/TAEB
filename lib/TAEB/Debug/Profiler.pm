package TAEB::Debug::Profiler;
use TAEB::OO;
use TAEB::Util 'sum';

has profile => (
    traits  => ['Collection::Hash'],
    is      => 'ro',
    isa     => 'HashRef[Num]',
    default => sub { {} },
    provides => {
        keys   => 'profile_categories',
        values => '_profile_times',
        get    => '_get_category_profile',
        set    => '_set_category_profile',
    },
);

sub add_category_time {
    my $self     = shift;
    my $category = shift;
    my $time     = shift;

    my $existing = $self->_get_category_profile($category) || 0;
    $self->_set_category_profile($existing + $time);
}

sub analyze {
    my $self = shift;
    my $profile = $self->profile;
    my $total_time = sum $self->_profile_times;

    my @results;
    for my $category (sort { $profile->{$b} <=> $profile->{$a} } keys %$profile) {
        push @results, [
            $category,
            $profile->{$category},
            $profile->{$category} / $total_time,
        ],
    }

    return @results;
}

__PACKAGE__->meta->make_immutable;
no TAEB::OO;

1;
