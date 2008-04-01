package WizardTestApp::Controller::First;

use base qw/Catalyst::Controller/;

use strict;
use warnings;


sub first_step : Local {
    my ($self, $c, $detach) = @_;

    $c->stash->{testsub} = 1    if $c->req->params->{testsub};
    $c->stash->{detach} = 1     if $c->req->params->{detach};

    my @steps = ('/first/first_step', '/first/second_step');

    @steps = (-detach => [ '/first/first_step', 'detach!' ],
                '/first/second_step')
            if $c->stash->{detach};

    $c->wizard(@steps);

    return if $c->wizard->goto_next;

    $c->res->body('Thats ok!') 
        if 
            $c->wizard->get('test') eq $c->wizard->delete('test') &&
            $c->stash->{test2} eq 'this also ok' && 
            (!$c->stash->{detach} || $detach eq 'detach!');
}

sub second_step : Local {
    my ($self, $c) = @_;

    if ($c->stash->{testsub}) {

        my @sub = ('/second/preved_step');

        if ($c->stash->{detach}) {
            @sub = (-detach => ['/second/preved_step', 10 ]);
        }

        $c->wizard(
            -first => (
                '-sub' => [ @sub ]
                , '+/first/second_step'
            )
        )->goto_next;
    } else {
        $c->wizard(
            -first => (
                '/second/preved_step'
                # а вот если здесь использовать -force,
                # то мы всё время будем добавлятся в очередь, не
                # важно были мы уже вызваны или нет - получится бесконечный 
                # цикл
                , '+/first/second_step'
            )
        )->goto_next;
    }
}

1;

__END__
