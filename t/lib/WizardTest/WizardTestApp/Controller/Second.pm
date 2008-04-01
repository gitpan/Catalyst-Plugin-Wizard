package WizardTestApp::Controller::Second;

use base qw/Catalyst::Controller/;

use strict;
use warnings;


sub preved_step : Local {
    my ($self, $c) = @_;

    $c->wizard->set('test' => 'ok');

    $c->stash->{test2} = 'this also ok' if !($c->stash->{testsub} && $c->stash->{detach}) || $_[2];

    #$c->wizard->stash;
    $c->wizard->goto_next;
}

1;

__END__
