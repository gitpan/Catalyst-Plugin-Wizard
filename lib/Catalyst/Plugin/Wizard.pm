# Wizard plugin - gathering data on multiply actions/pages instead of one
#
# DESCRIPTION
#   This plugin help you to save temporary data associated with concrete
#   actions (e.g. changing folder for service) in structure not in
#   session. Also it helps you to build correct actions queue 
#   (e.g. forward/redirect to correct pages)
#   
# # AUTHORS
#   Pavel Boldin (davinchi), <boldin.pavel@gmail.com>
#
#========================================================================

#============= STATIC/SINGLETON ===============
package Catalyst::Plugin::Wizard;

use strict;
use warnings;

use Catalyst::Plugin::Wizard::Instance;

use base qw/Class::Data::Inheritable/;

use Data::Dumper;
use Tie::IxHash;
use Storable;
use NEXT;

use Clone qw(clone);

__PACKAGE__->mk_classdata( 'wizards' => {} );

our $DEBUG = $ENV{CATALYST_WIZARD_DEBUG} || 0;

our $VERSION = 0.02;

sub instance { 
    shift->config->{wizard}->{instance} 
};

sub setup {
    my $self = shift;

    my %defaults = (
        timeout     => 3600,
        instance    => 'Catalyst::Plugin::Wizard::Instance',
    );

    while (my ($k, $v) = each %defaults) {
        if (!exists($self->config->{wizard}->{$k})) {
            $self->config->{wizard}->{$k} = $v;
        }
    }

    $self->NEXT::setup(@_);
}

# Всю ночь я видел одни только деревья
sub prepare_action {
    my $c = shift;

    # именно сначала вызываем next, только потом становится
    # доступным session. Смотри подробнее CP::Session
    $c->NEXT::prepare_action(@_);

    my $ma = $c->session->{wizards};

    warn 'loading: '.join(',', keys %$ma) if $DEBUG;

    foreach my $key (keys %$ma ) {
        ref $ma->{$key} or next;

        my %data = %{ $ma->{$key} };

        # устаревший wizard
        if ($data{created} && $data{created} + 
            $c->config->{wizard}->{timeout} < time) {
            warn 'wipeing wizard: '.$data{id} if $DEBUG;
            next;
        }
        
        warn "loaded: ".Dumper(\%data) if $DEBUG;

        $c->wizards->{$key} = $c->instance->new_from_data(%data);
        $c->wizards->{$key}->on_load($c);

    }

    do { local $^W = 0; $c->wizard } if $c->config->{wizard}{autoactivate};

}

sub finalize {
    my $c = shift;

    $c->session->{wizards} = {};

    my $active_wid = $c->req->params->{wid};

    # деактивируем ВСЕ активные wizard в сессии
    foreach (grep { $_->{active} } values %{$c->wizards}) {
        $_->on_deactivate($c);
    }

    # сохраняем их
    foreach my $key (keys %{ $c->wizards }) {
        my $wizard = delete $c->wizards->{$key};

        # устаревший wizard
        if ($wizard->{created} && $wizard->{created} + 
            $c->config->{wizard}->{timeout} < time) {
            warn 'wipeing wizard: '.$wizard->{id} if $DEBUG;
            next;
        }
        
        $wizard->on_save($c);

        warn 'saving '.Dumper($wizard) if $DEBUG > 2;

        $c->session->{wizards}->{$key} = 
                    $wizard->as_hashref;

    }

    warn 'saved = '.Dumper($c->session->{wizards}) if $DEBUG;

    return $c->NEXT::finalize(@_);
}

# получим текущий wizard
# если передаются параметры - действие с таким путём будет добавлено в стэк действий
# если нет wizard - он будет создан с этими actions
# если нет wizard и нет параметров - умирает с ошибкой
sub wizard {
    my $c = shift;

    warn 'wizard called: '.(join ', ',caller(0)) if $DEBUG > 2;
    my $wid = $c->req->params->{wid};

    if ($wid and my $wizard = $c->wizards->{$wid}) {

        warn "wid = $wid" if $DEBUG;
        do{ local $wizard->{c}; warn 'loaded = '.Dumper($wizard) } if $DEBUG;

        $wizard->add_steps(@_) if @_;

        $wizard->on_activate($c); 

        warn 'wizard found' if $DEBUG;

        return $wizard;
    }

    @_ or (warn 'No such wizard', return);


    return $c->start_wizard(@_);
}

# стартуем новое действие из нескольких action
sub start_wizard {
    my $c = shift;

    my $wizard = $c->instance->new (@_);

    $wizard->on_load($c);
    $wizard->on_activate($c);

    $c->req->params->{wid} = $wizard->id;

    $c->wizards->{$wizard->id} = $wizard;

    warn "wizard created: $wizard" if $DEBUG;

    $wizard;
}

sub stop_wizard {
    my $c = shift;

    my $wid = $c->req->params->{wid} or return;

    delete $c->wizards->{$wid};
}

# редирект к следующему действию в цепочке
sub redirect_next_action {
    my ($c, $default) = @_;

    return $c->wizard(-default => $default)->redirect;
}


sub forward_next_action {
    shift->wizard(-default => shift)->forward;
}

sub detach_next_action {
    shift->wizard(-default => shift)->detach;
}

1;


=head1 NAME

Wizard -- making multipart (e.g. wizard) actions: registering an user via several steps, 
submit something large (like application forms).

=head1 SYNOPSIS

    # if this called without previous wizard (i.e. new wizard) then
    # creating wizard with '/users/list' as first step and '/users/last' as second
    # otherwise append steps '/users/list' and '/users/last' if they wasn't added alread
    $c->wizard('/users/last', '/users/list');

    # going next step ('/users/list');
    $c->wizard->goto_next;

    # creating wizard with 'correct' (left to right) steps order
    $c->wizard(-first => '/users/list', '/users/last');
    $c->wizard->goto_next;

    # appending step '/users/list' and '+/users/list' -- this will add '/users/list' into wizard twice
    # you can prepend first '/' with any symbols you like -- just to make your step unique, so it will be added
    # into wizard
    $c->wizard(-first => '/users/list', '+/users/list', '/users/last');
    $c->wizard->goto_next; # to /users/list
    $c->wizard->goto_next; # again to /users/list

Something more real:

    package App;

    use strict;
    use warnings;

    use Catalyst qw/
        Session
        Session::Store::Dummy
        Session::State::Cookie

        Wizard
    /;

    # we assume stash automagically saves into wizard and restores from it
    __PACKAGE__->config({ wizard => { autostash => 1, autoactivate => 1 }});

    __PACKAGE__->setup;

    1;

    
    package App::C::First;

    use strict;
    use warnings;

    sub edit : Local {
        my ($self, $c) = @_;
        
        # goto 'login' wizard unless you are loggedin
        return $c->wizard(-first => '/first/login', '/first/edit')->goto_next unless $c->session->{loggedin};

        $c->res->body('OK!');
    }

    # draw login form
    sub login : Local {
        my ($self, $c) = @_;

        # adding destination of form as step
        $c->wizard('/first/login_submit');

        # dont forget to append wizard id into that form, and also use wizard->next call to
        # get action for form
        $c->res->body(<<EOF);
    <html>
        <head>
            <title>Test login</title>
        </head>
        <body>
            @{[delete $c->stash->{error} || '']}
            <form name="login" action="@{[ $c->wizard->next ]}">
                @{[ $c->wizard->id_to_form ]}
                <input name="username">
                <input name="password" type="password">
            </form>
        </body>
    </html>
    EOF

        $c->res->content_type('text/html');
    }

    # check login submited
    sub login_submit : Local {
        my ($self, $c) = @_;

        my $p = $c->req->params;

        # check if username and password are correct
        if ($p->{username} eq 'user' && $p->{password} eq 'userpassword') {
            $c->session->{loggedin} = 1;
            # ok, goto next ('/first/edit') in this example
            $c->wizard->goto_next;
        } else {
            $c->stash->{error} = 'Incorrect login'; 
            # incorrect, back to login page.
            $c->wizard->detach_prev(2);
        }
    }

    1;


=head1 DESCRIPTION

This plugin provides functionality for making multipart actions (wizards) more easily.

For example, you may need this plugin in following cases:

=over

=item *

When you need to move some items into another folder, you may: 
1) keep current folders select in session, 2) use it as wizard and keep that info in wizard (or stash)

=item *

When you need to deatch users into login page (see SYNOPSIS)

=back


=head1 METHODS

=head2 CATALYST METHODS

=head2 $c->wizard(...)

Returns new wizard (L<Catalyst::Plugin::Wizard::Instance>), existing one with steps 
you gave inserted into middle of flow, or undef, if no wizards are defined/seted.


When called without arguments it also 'activates' wizard 
(copying stash from wizard to catalyst if configured so, etc). 
You can configure plugin so your current active wizard will be autoactivated.

It takes step as an argument. Each step can be prefixed with keyword, which
alerts plugin how to work out this step. 
E.g. you use '/first/step' with some -prefixes => '/first/step'.

=head3 Step prefixes:

=over

=item Default behavior

Appends steps as an 'redirect' steps. Calling goto_next will cause 'redirect' jump into it.

NOTE: Last step in $c->wizard will be called first (like in stack), except for following case.

=item -first

MUST BE first in the chain. Signals that this $c->wizard call have steps arranged in left-to-right order.

=item -default

Addes -default target in step (called when all other steps are done).

=item -detach or -forward

Detaches or forwards to this step. Step can be either an simply string 
with action private path or arrayref within which 
$c->detach (or $c->forward) will be called.

=item -force

Forces adding step into wizard. 
Step will be added even if it already have been added into that wizard.
Use carefully! It can cause bugs!

=back

=head2 $c->start_wizard

Starts wizard with steps from arguments.

=head2 $c->stop_wizard

Stop current wizard.

=head2 $c->redirect_next_action($default_url)

Redirect to next action or to $default_url if no wizard exists 
or all wizard steps passed.

=head2 $c->detach_next_action($default_url)

Detaches to next action or to $default_url if no wizard exists 
or all wizard steps passed.

=head2 $c->forward_next_action($default_url)

Forwards to next action or to $default_url if no wizard exists 
or all wizard steps passed.


=head2 WIZARD METHODS (called via $c->wizard->...)

=head2 $c->wizard->add_steps(...) 

Used to add steps (within $c->wizard(...) args). 
You can use it if you won't need to create new wizard.
Args: same as for L<< $c->wizard(...) >> call.

=head2 $c->wizard->detach/forward/redirect

Detaches forwards or redirects to next step. You explicity select jump type.

=head2 $c->wizard->goto_next

Goto to next step in wizard 
(jump type -- forward, deatch or redirect -- decided automagically).

=head2 $c->wizard->next

Returns next destination -- arrayref for forward/deatch 
or string with action path for redirects 
(returns URI via subwizard id attached in case of subwizard)

=head2 $c->wizard->next_or_default

Returns I<< $c->wizard->next >> or default step.

=head2 $c->wizard->last

Returns last visited step (gets it from subwizard, if last step was from it).

=head2 $c->wizard->detach_prev($back)

Detaches I<$back> steps back.

=head2 $c->wizard->redirect_prev($back)

Redirects I<$back> steps back.

=head2 ACCESSORS

=head2 $c->wizard->data({...}) or $c->wizard->data->{...}

Data in wizard. Can be called within hashref as first argument to override 
current data. Returns hash with data.

=head2 $c->wizard->add(key1 => val1, key2 => val2) I<< (synonym: $c->wizard->set) >>

Sets key/value pairs in wizard data hash.

=head2 $c->wizard->get(key)

Gets entry from data hash with I<key>.


=head2 $c->wizard->stash({...}) or $c->wizard->stash->{...}

Stash in wizard. Can be copyed from $c via $c->wizard->copy_stash call 
(or automagically if configured so). 
Note that wizard stash will be copyed into $c only on next step.

=head2 $c->wizard->add_stash(key1 => val1, key2 => val2) I<< (synonym: $c->wizard->set_stash()) >>

Adds key/value pairs into wizard's stash.

=head2 $c->wizard->get_stash(key)

Gets stash value named I<key> from wizard's stash.

=head2 $c->wizard->params({...} or $c->wizard->params->{...}

Params in wizard. Same as stash in wizard.
Note that this will be copied into $c only on next step.

=head1 SEE ALSO

Catalyst::Plugin::Continuation, Catalyst::Plugin::Session.

=head1 AUTHOR

Pavel Boldin <boldin.pavel@gmail.com>

=cut
