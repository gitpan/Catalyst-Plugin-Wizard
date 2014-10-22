# 
#
# DESCRIPTION
#   Description
# # AUTHORS
#   Pavel Boldin (davinchi), <boldin.pavel@gmail.com>
#
#========================================================================

package Catalyst::Plugin::Wizard::Instance;

use strict;
use warnings;

use Time::HiRes;
use Digest::MD5;
use Carp;
use URI;
use HTML::Entities;

use Digest::MD5 qw(md5_hex);

use NEXT;
use Data::Dumper;
use overload '""' => \&id_to_uri;

our $DEBUG = $ENV{CATALYST_WIZARD_DEBUG} || 0;

#============= INSTANCE ===============

# �������� ����� wizard
sub new {
    my $class = shift;
    $class = ref $class || $class;

    my $id = int(rand(10000)); 
    #Digest::MD5::md5_hex(rand(1000000).join('', Time::HiRes::gettimeofday));

    my $self;

    # ID
    $self->{id}         = $id;
    # ������
    $self->{data}       = {};
    # ����, ����������� � $c->stash ��� on_activate
    $self->{stash}      = {};
    # ���������, ����������� � $c->request->params ��� on_activate
    $self->{params}     = {};
    # ����������� ����
    $self->{added}      = {};
    # ����� ��������
    $self->{created}    = time;
    # ������� ���
    $self->{step}       = 0;
    # ����
    $self->{steps}      = [];
    # �������
    $self->{prefix}     = '';
    
    $self = bless $self, $class;

    # ����
    $self->add_steps(@_);

    $self;
}

# �������� ��� hashref ��� ����������
sub as_hashref {
    my $self = shift;

    my %data = %$self;

    \%data;
}


# ������ ����� �� ������ (�� storage)
sub new_from_data {
    my $class = shift;
    my %data = @_;

    $class = ref $class || $class;

    bless \%data, $class;
}

# ������� ��� �� �� ������� wizard
sub life_forever {
    shift->{created} = 0;
}

##############################################################################
# �������� ������ ���������/��������� ������/stash/params
##############################################################################
# �������������/�������� ������

__PACKAGE__->mk_accessor_hash_chainable(set => 'data', 'get');
__PACKAGE__->mk_accessor_hash_chainable(set_stash => 'stash', 'get_stash');
__PACKAGE__->mk_accessor_hash_chainable(set_params => 'params', 'get_params');

{ 
    no warnings 'once';
    *add        = \&set;
    *add_stash  = \&set_stash;
    *add_params = \&set_params;
}

foreach(qw(data stash params)) {
    __PACKAGE__->mk_accessor_simply($_);
}

foreach(qw(c parentid)) {
    __PACKAGE__->mk_accessor_chainable($_);
}


sub delete {
    my $self = shift;

    @_ == 1 or confess 'Error in delete arguments';

    return delete @{$self->{data}}{@_};
}

##############################################################################
# ������ ��������� id ������������ ���
##############################################################################

sub id {
    shift->{id};
}

sub id_to_uri {
    my $self = shift;
    'wid='.$self->id.'&step='.$self->{step};
}

sub id_to_form {
    my $self = shift;

    "<input type=\"hidden\" name=\"wid\"    value=\"@{[$self->id]}\" />\n".
    "<input type=\"hidden\" name=\"step\"   value=\"$self->{step}\"  />\n";
}

sub to_uri {
    my $self = shift;

    my $uri = new URI;

    $uri->query_form($self->{data});

    $uri;
}

sub to_form {
    my $self = shift;

    my $output;

    foreach my $fld (keys %{$self->{data}}) {
        $output .= "<input type=\"hidden\" name=\"$fld\" value=\"";
        $output .= encode_entities($self->{data}->{$fld});
        $output .= "\"/>\n";
    }

    $output;
}

################################################################################
# ������ ������������ ������� - ��� ��������, ����������, ���������, �����������
################################################################################
sub on_save {
    my ($self, $c) = @_;

    # ������� {c}, ��� �� ��� �� ��������� � session (��������, ���)
    delete $self->{c};
}

# ������������� c
sub on_load {
    shift->c(shift);
}

# ��� ���������
sub on_activate {
    my ($self, $c) = @_;

    # ��� ������������� - �������
    return if $self->{active};

    # ������� ��� stash � ����������
    if (keys %{$self->{stash}}) {
        $c->stash->{$_} = $self->{stash}->{$_} foreach keys %{$self->{stash}};
    }

    # �������� ���� params � Catalyst
    if (keys %{$self->{params}}) {
        $c->request->params->{$_} = $self->{params}->{$_} foreach keys %{$self->{params}};
    }

    # ������� - � �� ��� �� ��� �����
    # � ���� ��, � ��� ���� ��������� � ��� ��� ����� ���� - 
    # ������ ����� �������� ����
    # ���� ������� ��� '����� ���������' ? :-)
    if (my $step = $c->req->params->{step}) {
        my $current_path = $c->req->uri;
        # ����� �������� ��� ������ ��� ��� (�� ������� �� ���������)
        # ��� �� ����� ���� �� ������� ������
        #warn "$step, $self->{step}, $current_path, $self->{steps}[$step - 1]";
        if (    $step < $self->{step}
            &&  $self->{steps}[$step - 1] 
            &&  index($current_path, $self->{steps}[$step - 1]) >= 0 ) {

            $self->{step} = $step;
        }
    }


    # ����������������
    $self->{active} = 1;
}

# �����������
sub on_deactivate {
    my ($self, $c) = @_;

    # �������� Catalyst stash � ��� ���� ��� �����������������
    $self->copy_stash if $c->config->{wizard}{autostash};

    warn "Deactivating with ".$self->parentid if $DEBUG;
    if ( $DEBUG && $self->parentid ) {
	local $self->{c};
	warn Dumper($self);
    }
    # ���� ���� �������� (��� sub wizard) � �� �� ��������� ����
    # �������� ���� ������ � ��������
    if ($self->parentid && $self->{step} >= scalar @{$self->{steps}} ) {
        my $p_wizard = $c->wizards->{$self->parentid};

        foreach my $field (qw(data stash params)) {
            my @keys = keys %{ $self->{$field} };

            foreach my $k (@keys) {
                $p_wizard->{$field}{$k} ||= $self->{$field}{$k};
            }
        }
    }

    # ������� ������� �� ����������
    delete $self->{active};
}

# ���������� ������� ��������� mark
sub _get_mark_for_action {
    my $self = shift;
    my $action = shift;

    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Sortkeys = 1;

    # NOTE �� ���! ����� ������ ���������� �� �� ������, ����� ���
    # ����� ������ ��� 
    # (�������� 
    #   -sub => [ -detach => [ '/test', [ 10, 20 ] ]
    #   -sub => [ -detach => [ '/test', [ 20, 10 ] ]) - ��������
    return md5_hex(Dumper($action)) unless $_[0];

    return join ('|', map { ref $_ && md5_hex(Dumper($_)) || $_ } ('sub', @$action)) if $_[0] eq 'subwizard';

}


# ��������������� ������� ��� ��������������� sub wizard
sub _construct_sub {
    my $self = shift;

    my @options = @{shift()};

    # �������� ������� (�.�. ��� ��������)
    my $mark = $self->_get_mark_for_action(\@options, 'subwizard');

    # ������������ ���� �� ��� ���������
    return if $self->{added}{$mark};

    # �������� ����� subwizard
    # ���� - ��� ������ ����, ������ ��� ���������
    # --NOTE: start_wizard ������ params->{wid} �� ��� subwizard id,
    # ��� ��� ��������� wizard(-sub ... ) ������ ����� ����� ���������--
    my $sub = do {
        local $self->c->req->params->{wid};
	warn "Creating sub wizard..."    if ($DEBUG);
        $self->c->start_wizard(@options);
    };

    # ������������� parentid
    $sub->parentid($self->id);

    # ����� �������� (���� � ���������)
    $sub->{created} = $self->{created};
    
    # �������� �������
    $sub->{prefix}  = $self->{prefix};

    # ���������� - �������� ��� *DRINK*
    $self->{added}{$mark} = 1;

    # �������� ���� � ����������
    $sub->{$_} = { %{ $self->{$_} } } foreach qw(data stash params added);

    if ($DEBUG) { 
        local $sub->{c};
        warn Dumper($sub);
    }

    #���������� ID sub wizard'�
    return "$sub";
}

sub _make_prefix {
    my ($self, $step) = @_;

    # ����� ��� ������� ������������?
    # ���� prefix ���� -- �� ���� ������ ������
    return $step unless $self->{prefix};

    # �������� (��������� � $1) ����������� � ����
    $step =~ s,^(.*?)/,/,;
    # ��������: �����������, �������, ��� ��� �����������
    $step = $1.$self->{prefix}.$step;
    # �������� ������� //
    $step =~ s,//,/,g;

    return $step;
}

# ��������� ����. ������� ����� ������� �������
sub add_steps {
    my $self = shift;

    warn 'pushing actions: '.join (', ', @_) if $DEBUG;

    my @steps = @_;

    my @new_steps;

    my $direct = 0;
    my $skip = 0;

    while(my $step = shift @steps) {

        # ����������� - �� ��������� � ���� �����,
        # ��� ������������� -first - � ������� 'first in first out (gotoed)'
        if ( $step eq '-first' ) {
            $direct = 1;

            die "-first should be BEFORE any steps" if @new_steps;

            warn "left-to-right order" if $DEBUG;
            next;
        }

        if ( $step eq '-skip' ) {
            $skip++;
            next;
        }

        # ���� -default - ������������� ���
        if ( $step eq '-default' ) {
            # ������ �� ||= shift, �.�. ��������� �� ������ �������� ������
            my $next = shift @steps;

            # ���� next => undef -- � ���������� ����
            next unless defined $next;

            # ���������� ���
            $next = $self->_make_prefix($next);

            warn "settings default as $next" if $DEBUG;

            $self->{default} ||= $next;
            next;
        }

        # ���� -prefix - ������������� � ��� ����
        if ( $step eq '-prefix' ) {
            my $prefix = shift @steps;

            # � ���������� ����, ���� ��� ����������
            next if $self->{prefix};

            $self->{prefix} = $prefix;

            # ���� ������ �������� �������� / � ����� �/��� ������
            $self->{prefix} = "/$self->{prefix}/";
            $self->{prefix} =~ s,//,/,g;

            warn "set prefix to $self->{prefix}" if $DEBUG;
            next;
        }

        # �� �������� -sub
        if ( $step eq '-sub' ) {
            # ��� ����� ����������� ������ � -first
            die "-sub can only be used with -first" unless $direct;

            # �������� ��� id
            my $subid =
                $self->_construct_sub(shift @steps);

            last unless defined $subid;

            # ��������� � �������
            push @new_steps, $subid;
            next;
        }

        # -detach ��� -forward
        # �� �� �� prefix'��� - ��� private path, ��� �������
        if ( $step eq '-detach' || $step eq '-forward' ) {
            my $goto_type = $step;

            # �������� ����� ��� ���������
            $step = shift @steps;

            # ��� ��������
            if (ref $step eq 'ARRAY') {
                $step = [ $goto_type, @$step ];
            } else {
                $step = [ $goto_type, $step ];
            }
        }

        # �������� mark ��� ����� action
        my $mark = $self->_get_mark_for_action($step);

        # ���� ���� �� ���� �� ���� ������� ��� ��� ��������
        # �� �� ��������� ��� ������� � ������� ���������
        # wizard
        if ( $self->{added}{$mark} ) {

            # �� ��������� �� ��� ��� ����� (�.�. �������� ������� �����
            # �������� ��)
            last unless $direct;

            # �� ��������� �� ��� ��� �� (�.�. �������� ��)
            @new_steps = ();
            next;
        }

        # ������ � ���������� ������������:
        # $c->wizard('/test', '/test2', '/test3') - 
        # ���� '/test2' ��� ��� �������, ����� �� � test3 �� ����� ���������
        # ���� �� ��� ������� '/test' - �� ����� ������ �� ��������� � wizard

        # (��� ����� �������� ����� ���������� /test �������� $c->wizard, 
        # ����������� � /test2, � ����� ����� �������� ���������� 
        # �� test2 ��������� ��� detach/forward,
        # ����� /test �� ����� �������� �������� � ������ (��� � /test2)

        # � ������ ���� 
        # $c->wizard(-first => '/test3', '/test2', '/test')
        # ���� /test ��� ��� ������� - ������ �� ����� ���������
        # ���� ������� /test2 - �� � /test3 �� ����� ���������

        # ���� ������ ������ - 
        # ��� ��� ���������� �� /test2 � /test ��� ���������� ���������� 
        # � visited 
        # (�.�. ��������� engine � �� ������� ->next ��� ->goto_next) - 
        # ��� ������� � ���������� (��������) ������ /test. 
        # ������ ��� ��� ��������, ������ ��� ��� wizard('/test',...)->goto_next


        # ���� -force ��� ���������� - ��������� ��� ��������
        if ( $step eq '-force' ) {
            $step = shift @steps;
        }
        else {
            # ��������� ���� �� -force
            $self->{added}{$mark} = 1;

        }

        # ������ prefix...
        $step = $self->_make_prefix($step) unless ref ($step);

        # ��� ����� �����-��-�����
        push @new_steps, $step;
    }

    # ���, ���� ���� ������-��-����
    unless ( $direct ) {
        warn "Reversing because is NOT direct" if $DEBUG;
        @new_steps = reverse @new_steps;
    }

    if (@new_steps) {
        warn "new_steps = @new_steps" if $DEBUG;

        splice @{$self->{steps}}, $self->{step}, 0, @new_steps;
    }

    # ���������� ������ ���������....
    $self->{step} += $skip if $skip;

    warn "Steps after adding: ".Dumper($self->{steps}) if $DEBUG;
    warn "current step: $self->{step}" if $DEBUG;

}

# ��������� wizard...
sub renew {
    shift->{step} = 0;
}

# �������� ��� ���������� ����, �� ������� �������
sub last {
    my $self = shift;

    my $step_n = $self->{step} - 1;

    return if $step_n < 0;

    my $last_step = $self->{steps}->[$step_n];

    # ���� ��� ��� sub wizard
    if ( $last_step =~ /wid=(\d+)/) {
        my $wizard = $self->c->wizards->{$1};

        return unless $wizard;

        # �������� ��� ��� ���������� ��������
        return $wizard->last;
    }

    # ���� ��� detach/forward - �������� �������� �� �������
    $last_step = $last_step->[1] if ref $last_step eq 'ARRAY';

    # ������� + � ������
    #$last_step =~ s/\++//;
    $last_step =~ s,^.*?/,/,;

    return $last_step;
}

# �������� ��� ����� step
sub get_step {
    my $self = shift;
    my %param = (append_self => 1, step => $self->{step}, @_);

    my $step_n = $param{step};

    # ���� ������ :-/
    return if $step_n >= @{$self->{steps}};

    # ��������
    my $step = $self->{steps}->[$step_n];

    warn "wid = $self->{id}" if $DEBUG;
    warn "step is = $step" if $DEBUG;
    # ���� ��� sub wizard
    if ($step && $step =~ /wid=(\d+)/) {
        # ������� ���
        my $wizard = $self->c->wizards->{$1};

        return unless $wizard;

        # ������� ��� next_or_default
        my @ret = $wizard->next_or_default(append_self => 1);

        # � ���������� ����������, �� ������� ������ params->{wid}
        if (@ret) {
            $self->c->req->params->{wid} = $wizard->id;
            return wantarray ? @ret : $ret[0];
        }

        return $self->get_step(%param, step => $param{step} + 1);
    }

    warn "step = $self->{step}" if $DEBUG;

    if ($step) {
        # ��������� �� ������ (rediret)
        if (!ref $step) {
            $step =~ s,^.*?/,/,;
            return $param{append_self} ? $step.'?'.$self : $step;
        } elsif (ref $step ne 'ARRAY') {
            return $step;
        } elsif ($step->[0] eq '-detach' || $step->[0] eq '-forward') {
            # ��������� �� detach/forward
            $step->[1] =~ s,^.*?/,/,;

            # step->[0] - ��� ������ (forwad/detach)
            # step->[1] - ��������
            # step->[2...] - ���������

            # detach/forward ��������� ���������:
            # 1) private path � action
            # 2) arrayref � ����������� ��� ������

            my $detach_forward_args = [ $step->[1], [ @$step[2..$#$step] ] ];

            if (wantarray) {
                # ���������� ������������� + ��� ��������
                return ($detach_forward_args, $step->[0]);
            } else {
                # ���������� ������ �������������
                return $detach_forward_args;
            }
        }
    }
}

# �������� ��������� ���
sub next {
    my $self = shift;

    my @next = $self->get_step(@_);

    $self->{step}++;

    @next;
}

# �������� ��������� ��� ������ �� ���������
sub next_or_default {
    my $self = shift;

    my @next = $self->next(@_);

    warn "returning next_or_default: @next" if $DEBUG;

    return wantarray ? @next : $next[0] if @next;

    warn "$self->{id} and parent is: ".$self->parentid if $DEBUG;

    # ������� ������ wizard ���� ��� ������ ������ ����
    # (������� ��������� ����� :-( )
    $self->{created} = 1 unless $self->parentid;

    warn "default => $self->{default}" if $DEBUG;

    if ( $self->{default} ) {
        return wantarray ? ($self->{default}, 'default') : $self->{default} 
    }

    if ( $self->parentid ) {
        my $parent = $self->c->wizards->{$self->parentid} or return;

        warn "getting parent: $parent" if $DEBUG;
        # ������� ��� �� �������� �������� ���� (��� ������� �� ����������
        # � append_self => 0 �� ->goto_next
        #
        # _goto ������� - ���� �� � "����" wid=(\d+) 
        # � ���� ���� - �� ��������� ������� wizard
        return $parent->next_or_default(@_, append_self => 1);
    }

    return { @_ }->{goto} if @_;

    return;
}

sub _goto {
    my ($self, $step, $action) = @_;

    if (!defined $action && $step) {
        warn "goto_step = $step" if $DEBUG;
        # ���� ��� �������� �� subwizard  ��� ��� parent
        if ($step =~ /wid=(\d+)/oi) {
            # �� ��������� ���� wid
            warn "Jump betweeen wizards: from $self->{id} to $1" if $DEBUG;
            return $self->c->res->redirect($step) 
        } else {
            # ����� ���������
            return $self->c->res->redirect($step.'?'.$self) 
        }
    }

    return unless defined $action;

    return $self->c->res->redirect($step) if $action eq 'default';

    return $self->c->detach(    ref $step ? @$step : $step ) 
                                            if $action eq '-detach';

    return $self->c->forward(   ref $step ? @$step : $step ) 
                                            if $action eq '-forward';
}

# ����� �� ��� $action
sub back_to {
    my ($self, $action, $type) = @_;

    my $i = 0;

    foreach my $step ( @{$self->{steps}} ) {
        if ( not ref $step ) {
            $step eq $action and last;
        } elsif ( ref $step eq 'ARRAY' ) {
            $step->[0] eq $action and last;
        }

        $i++;
    }

    if ( $i == @{$self->{steps}} ) {
        return;
    }

    $self->{step} = $i;

    return $self->goto_next($type ? "-$type" : ());
}

# detach $back ����� �����
sub detach_prev {
    my ($self, $back) = @_;

    $back ||= 1;

    $self->{step} -= $back;

    return $self->goto_next(-detach =>);
}

# redirect $back ����� �����
sub redirect_prev {
    my ($self, $back) = @_;

    $back ||= 1;

    $self->{step} -= $back;

    return $self->redirect;
}

# ��������� � ���������� �������� � ������� �������� ��� ���������
sub goto_next {
    my ($self, $action) = @_;

    (my ($step), $action) = ($self->next_or_default(append_self => 0), $action);

    warn "step = @{[ ref $step ? @$step : $step ]}, action = $action" if $DEBUG;

    return $self->_goto($step, $action);
}

sub redirect {
    my ($self, $c) = @_;
    my $url = $self->next_or_default;

    $self->c($c) if $c;

    return $self->c->res->redirect($url) if $url;
}

sub forward {
    my ($self, $c) = @_;
    my $url = $self->next_or_default;

    $self->c($c) if $c;

    return $self->c->forward(@$url);
}

sub detach {
    my ($self, $c) = @_;
    my $url = $self->next_or_default;

    $self->c($c) if $c;

    return $self->c->detach(@$url);
}

# �������� stash �� Catalyst � Wizard
sub copy_stash {
    my ($self) = @_;

    my $c = $self->c;

    foreach (keys %{$c->stash}) {
        $self->{stash}{$_} = $c->stash->{$_};
    }
}

sub mk_accessor_chainable {
    my ($class, $name) = @_;

    no strict 'refs';

    *{$class.'::'.$name} = sub {
        my ($self) = shift;

        return $self->{$name} unless @_;
        
        $self->{$name} = shift;

        $self;
    };
}

sub mk_accessor_hash_chainable {
    my ($class, $name, $field, $get) = @_;

    no strict 'refs';

    *{$class.'::'.$name} = sub {
        my ($self) = shift;

        return $self->{$field} unless @_;

        @_ % 2 == 0 or confess "Odd elements in setting hash $field";

        while (@_) {
            my $subfld  = shift;
            my $val     = shift;

            $self->{$field}{$subfld} = $val;
        }

        $self;
    };

    if ($get) {
        *{$class.'::'.$get} = sub {
            my $self = shift;

            @_ == 1 or confess "incorrect arguments in $get";

            $self->{$field}{shift()};
        }
    }
}

sub mk_accessor_simply {
    my ($class, $name) = @_;

    no strict 'refs';

    *{$class.'::'.$name} = sub {
        my $self = shift;
        if ( @_ ) {
            my %data = @_;
            $self->{$name} = \%data;
        }

        $self->{$name};
    }
}

1;

=head1 NAME

Catalyst::Plugin::Wizard::Instance -- instance of wizard for wizard plugin.

=head1 DESCRIPTION

Never read this code...

=head1 AUTHOR

Pavel Boldin <boldin.pavel@gmail.com>

=cut
