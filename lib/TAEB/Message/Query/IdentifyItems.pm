package TAEB::Message::Query::IdentifyItems;
use TAEB::OO;
extends 'TAEB::Message::Query';
with 'TAEB::Message::Role::SelectSubset';

__PACKAGE__->meta->make_immutable;
no TAEB::OO;

1;

