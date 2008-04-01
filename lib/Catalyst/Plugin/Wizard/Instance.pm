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

# Создадим новый wizard
sub new {
    my $class = shift;
    $class = ref $class || $class;

    my $id = int(rand(10000)); 
    #Digest::MD5::md5_hex(rand(1000000).join('', Time::HiRes::gettimeofday));

    my $self;

    # ID
    $self->{id}         = $id;
    # данные
    $self->{data}       = {};
    # стэш, добавляемый в $c->stash при on_activate
    $self->{stash}      = {};
    # параметры, добавляемые в $c->request->params при on_activate
    $self->{params}     = {};
    # добавленные шаги
    $self->{added}      = {};
    # время создания
    $self->{created}    = time;
    # текущий шаг
    $self->{step}       = 0;
    # шаги
    $self->{steps}      = [];
    # префикс
    $self->{prefix}     = '';
    
    $self = bless $self, $class;

    # шаги
    $self->add_steps(@_);

    $self;
}

# получаем как hashref для сохранения
sub as_hashref {
    my $self = shift;

    my %data = %$self;

    \%data;
}


# создаём новый из данных (из storage)
sub new_from_data {
    my $class = shift;
    my %data = @_;

    $class = ref $class || $class;

    bless \%data, $class;
}

# говорим что бы не убивали wizard
sub life_forever {
    shift->{created} = 0;
}

##############################################################################
# Огромная секция установки/получения данных/stash/params
##############################################################################
# устанавливаем/получаем данные

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
# Секция получения id сериализации итд
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
# Секция обработчиков событий - при загрузке, сохранении, активации, деакцтиваци
################################################################################
sub on_save {
    my ($self, $c) = @_;

    # удаляем {c}, что бы его не сохранило в session (рекурсия, ага)
    delete $self->{c};
}

# устаналвиваем c
sub on_load {
    shift->c(shift);
}

# при активации
sub on_activate {
    my ($self, $c) = @_;

    # уже активированны - пропуск
    return if $self->{active};

    # копирем наш stash в глобальный
    if (keys %{$self->{stash}}) {
        $c->stash->{$_} = $self->{stash}->{$_} foreach keys %{$self->{stash}};
    }

    # копируем наши params в Catalyst
    if (keys %{$self->{params}}) {
        $c->request->params->{$_} = $self->{params}->{$_} foreach keys %{$self->{params}};
    }

    # смотрим - а не шаг ли это назад
    # и если да, и шаг этот совпадает с тем что тогда было - 
    # меняем номер текущего шага
    # споём песенку про 'стошу говнозада' ? :-)
    if (my $step = $c->req->params->{step}) {
        my $current_path = $c->req->uri;
        # нужно заметить что нужный нам шаг (на который мы вернулись)
        # это на самом деле на единицу меньше
        #warn "$step, $self->{step}, $current_path, $self->{steps}[$step - 1]";
        if (    $step < $self->{step}
            &&  $self->{steps}[$step - 1] 
            &&  index($current_path, $self->{steps}[$step - 1]) >= 0 ) {

            $self->{step} = $step;
        }
    }


    # активизировались
    $self->{active} = 1;
}

# деакцтиваия
sub on_deactivate {
    my ($self, $c) = @_;

    # копируем Catalyst stash к нам если так сконфигурированно
    $self->copy_stash if $c->config->{wizard}{autostash};

    # если есть родитель (это sub wizard) и мы на последнем шаге
    # копируем наши данные к родителю
    if ($self->parentid && $self->{step} == scalar @{$self->{steps}} ) {
        my $p_wizard = $c->wizards->{$self->parentid};

        foreach my $field (qw(data stash params)) {
            my @keys = keys %{ $self->{$field} };

            foreach my $k (@keys) {
                $p_wizard->{$field}{$k} ||= $self->{$field}{$k};
            }
        }
    }

    # удаляем пометку об активности
    delete $self->{active};
}

# используем простое получение mark
sub _get_mark_for_action {
    my $self = shift;
    my $action = shift;

    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Sortkeys = 1;

    # NOTE НЕ баг! нужно всегда передавать ТЕ ЖЕ данные, иначе это
    # будет другой шаг 
    # (например 
    #   -sub => [ -detach => [ '/test', [ 10, 20 ] ]
    #   -sub => [ -detach => [ '/test', [ 20, 10 ] ]) - РАЗЛИЧНЫ
    return md5_hex(Dumper($action)) unless $_[0];

    return join ('|', map { ref $_ && md5_hex(Dumper($_)) || $_ } ('sub', @$action)) if $_[0] eq 'subwizard';

}


# вспомогательная функция для конструирования sub wizard
sub _construct_sub {
    my $self = shift;

    my @options = @{shift()};

    # получаем отметку (т.е. своё название)
    my $mark = $self->_get_mark_for_action(\@options, 'subwizard');

    # возвращаемся если мы уже добавлены
    return if $self->{added}{$mark};

    # стартуем новый subwizard
    # ниже - так раньше было, сейчас это пофикшено
    # --NOTE: start_wizard меняет params->{wid} на наш subwizard id,
    # так что вызывайте wizard(-sub ... ) только прямо перед переходом--
    my $sub = do {
        local $self->c->req->params->{wid};
        $self->c->start_wizard(@options);
    };

    # устанавливаем parentid
    $sub->parentid($self->id);

    # время создания (одно с родителем)
    $sub->{created} = $self->{created};
    
    # копируем префикс
    $sub->{prefix}  = $self->{prefix};

    # добавились - отмечаем это *DRINK*
    $self->{added}{$mark} = 1;

    # копируем себя в наследника
    $sub->{$_} = \%{ %{$self->{$_}} } foreach qw(data stash params added);

    if ($DEBUG) { 
        local $sub->{c};
        warn Dumper($sub);
    }

    #возвращаем ID sub wizard'а
    return "$sub";
}

sub _make_prefix {
    my ($self, $step) = @_;

    # опять эти нелепые телодвижения?
    # если prefix пуст -- не надо ничего делать
    return $step unless $self->{prefix};

    # отрезаем (запоминая в $1) спецотметки у шага
    $step =~ s,^(.*?)/,/,;
    # слепляем: спецотметки, префикс, шаг без спецотметов
    $step = $1.$self->{prefix}.$step;
    # заменяем двойные //
    $step =~ s,//,/,g;

    return $step;
}

# добавляем шаги. пожалуй самая сложная функция
sub add_steps {
    my $self = shift;

    warn 'pushing actions: '.join (', ', @_) if $DEBUG;

    my @steps = @_;

    my @new_steps;

    my $direct = 0;
    my $skip = 0;

    while(my $step = shift @steps) {

        # направление - по умолчанию в виде стэка,
        # при использовании -first - в порядке 'first in first out (gotoed)'
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

        # если -default - устанавилваем его
        if ( $step eq '-default' ) {
            # учтите НЕ ||= shift, т.к. последний не всегда сдвигает массив
            my $next = shift @steps;

            # если next => undef -- к следующему шагу
            next unless defined $next;

            # префиксуем его
            $next = $self->_make_prefix($next);

            warn "settings default as $next" if $DEBUG;

            $self->{default} ||= $next;
            next;
        }

        # если -prefix - устанавливаем и его тоже
        if ( $step eq '-prefix' ) {
            my $prefix = shift @steps;

            # к следуюгему шагу, если уже установили
            next if $self->{prefix};

            $self->{prefix} = $prefix;

            # люди всегда забывают добавить / в конце и/или начале
            $self->{prefix} = "/$self->{prefix}/";
            $self->{prefix} =~ s,//,/,g;

            warn "set prefix to $self->{prefix}" if $DEBUG;
            next;
        }

        # мы получили -sub
        if ( $step eq '-sub' ) {
            # его можно исползовать только с -first
            die "-sub can only be used with -first" unless $direct;

            # получаем его id
            my $subid =
                $self->_construct_sub(shift @steps);

            last unless defined $subid;

            # добавляем и выходим
            push @new_steps, $subid;
            next;
        }

        # -detach или -forward
        # их мы НЕ prefix'уем - они private path, как помните
        if ( $step eq '-detach' || $step eq '-forward' ) {
            my $goto_type = $step;

            # получаем какой шаг переходит
            $step = shift @steps;

            # тип перехода
            if (ref $step eq 'ARRAY') {
                $step = [ $goto_type, @$step ];
            } else {
                $step = [ $goto_type, $step ];
            }
        }

        # получаем mark для этого action
        my $mark = $self->_get_mark_for_action($step);

        # если хотя бы один из всей цепочки был уже добавлен
        # мы не добавляем ВСЮ цепочку с который вызывался
        # wizard
        if ( $self->{added}{$mark} ) {

            # не добавляем всё что идёт после (т.е. действия которые нужно
            # добавить до)
            last unless $direct;

            # не добавляем всё что идёт до (т.е. действия до)
            @new_steps = ();
            next;
        }

        # ПРИМЕР к предыдущим комменатриям:
        # $c->wizard('/test', '/test2', '/test3') - 
        # если '/test2' был уже посещён, тогда он и test3 не будут добавлены
        # если же был посещён '/test' - то тогда ничего не добавится в wizard

        # (это нужно например когда обработчик /test вызывает $c->wizard, 
        # переходящий к /test2, а затем снова получает управление 
        # от test2 переходом или detach/forward,
        # тогда /test не будет повторно добавлен и вызван (как и /test2)

        # в случае если 
        # $c->wizard(-first => '/test3', '/test2', '/test')
        # если /test уже был посещён - ничего не будет добавлено
        # если посещён /test2 - он и /test3 не будут добавлены

        # чего НЕЛЬЗЯ делать - 
        # так это переходить из /test2 в /test без добавления последнего 
        # в visited 
        # (т.е. обманывая engine и не вызывая ->next или ->goto_next) - 
        # это приведёт к повторному (двойному) вызову /test. 
        # первый раз при переходе, второй раз при wizard('/test',...)->goto_next


        # если -force при добавлении - добавляем без вопросов
        if ( $step eq '-force' ) {
            $step = shift @steps;
        }
        else {
            # добавляем если не -force
            $self->{added}{$mark} = 1;

        }

        # делаем prefix...
        $step = $self->_make_prefix($step) unless ref ($step);

        # как будто слева-на-право
        push @new_steps, $step;
    }

    # ага, надо было справа-на-лево
    unless ( $direct ) {
        warn "Reversing because is NOT direct" if $DEBUG;
        @new_steps = reverse @new_steps;
    }

    if (@new_steps) {
        warn "new_steps = @new_steps" if $DEBUG;

        splice @{$self->{steps}}, $self->{step}, 0, @new_steps;
    }

    # пропускаем первые несколько....
    $self->{step} += $skip if $skip;

    warn "Steps after adding: ".Dumper($self->{steps}) if $DEBUG;
    warn "current step: $self->{step}" if $DEBUG;

}

# обновляем wizard...
sub renew {
    shift->{step} = 0;
}

# получаем имя последнего шага, на который перешли
sub last {
    my $self = shift;

    my $step_n = $self->{step} - 1;

    return if $step_n < 0;

    my $last_step = $self->{steps}->[$step_n];

    # если это был sub wizard
    if ( $last_step =~ /wid=(\d+)/) {
        my $wizard = $self->c->wizards->{$1};

        return unless $wizard;

        # получаем имя его последнего действия
        return $wizard->last;
    }

    # если это detach/forward - получаем действие из массива
    $last_step = $last_step->[1] if ref $last_step eq 'ARRAY';

    # удаляем + в начале
    #$last_step =~ s/\++//;
    $last_step =~ s,^.*?/,/,;

    return $last_step;
}

# получаем шаг номер step
sub get_step {
    my $self = shift;
    my %param = (append_self => 1, step => $self->{step}, @_);

    my $step_n = $param{step};

    # нету такого :-/
    return if $step_n >= @{$self->{steps}};

    # действие
    my $step = $self->{steps}->[$step_n];

    warn "wid = $self->{id}" if $DEBUG;
    warn "step is = $step" if $DEBUG;
    # если это sub wizard
    if ($step && $step =~ /wid=(\d+)/) {
        # находим его
        my $wizard = $self->c->wizards->{$1};

        return unless $wizard;

        # полчаем его next_or_default
        my @ret = $wizard->next_or_default(append_self => 1);

        # и возвращаем полученное, но сначала ставим params->{wid}
        if (@ret) {
            $self->c->req->params->{wid} = $wizard->id;
            return wantarray ? @ret : $ret[0];
        }

        return $self->get_step(%param, step => $param{step} + 1);
    }

    warn "step = $self->{step}" if $DEBUG;

    if ($step) {
        # переходим по ссылке (rediret)
        if (!ref $step) {
            $step =~ s,^.*?/,/,;
            return $param{append_self} ? $step.'?'.$self : $step;
        } elsif (ref $step ne 'ARRAY') {
            return $step;
        } elsif ($step->[0] eq '-detach' || $step->[0] eq '-forward') {
            # переходим по detach/forward
            $step->[1] =~ s,^.*?/,/,;

            # step->[0] - тип прыжка (forwad/detach)
            # step->[1] - действие
            # step->[2...] - аргументы

            # detach/forward принимают аргументы:
            # 1) private path к action
            # 2) arrayref с аргументами для вызова

            my $detach_forward_args = [ $step->[1], [ @$step[2..$#$step] ] ];

            if (wantarray) {
                # возвращаем вышеописанное + тип действия
                return ($detach_forward_args, $step->[0]);
            } else {
                # возвращаем только вышеописанное
                return $detach_forward_args;
            }
        }
    }
}

# получаем следующий шаг
sub next {
    my $self = shift;

    my @next = $self->get_step(@_);

    $self->{step}++;

    @next;
}

# получаем следующий или прыжок по умолчанию
sub next_or_default {
    my $self = shift;

    my @next = $self->next(@_);

    warn "returning next_or_default: @next" if $DEBUG;

    return wantarray ? @next : $next[0] if @next;

    # удаляем старый wizard если ему некуда больше идти
    # (убиваем бездомных сирот :-( )
    $self->{created} = 1 unless $self->parentid;

    warn "default => $self->{default}" if $DEBUG;

    if ( $self->{default} ) {
        return wantarray ? ($self->{default}, 'default') : $self->{default} 
    }

    if ( $self->parentid ) {
        my $parent = $self->c->wizards->{$self->parentid} or return;

        warn "getting parent: $parent" if $DEBUG;
        # говорим что бы родитель добавлял себя (как правило мы вызываемся
        # с append_self => 0 из ->goto_next
        #
        # _goto смотрит - есть ли в "пути" wid=(\d+) 
        # и если есть - не добавляет текущий wizard
        return $parent->next_or_default(@_, append_self => 1);
    }

    return { @_ }->{goto} if @_;

    return;
}

sub _goto {
    my ($self, $step, $action) = @_;

    if (!defined $action && $step) {
        warn "goto_step = $step" if $DEBUG;
        # если это редирект на subwizard  или его parent
        if ($step =~ /wid=(\d+)/oi) {
            # не добавляем свой wid
            warn "Jump betweeen wizards: from $self->{id} to $1" if $DEBUG;
            return $self->c->res->redirect($step) 
        } else {
            # иначе добавляем
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

# назад на шаг $action
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

# detach $back шагов назад
sub detach_prev {
    my ($self, $back) = @_;

    $back ||= 1;

    $self->{step} -= $back;

    return $self->goto_next(-detach =>);
}

# redirect $back шагов назад
sub redirect_prev {
    my ($self, $back) = @_;

    $back ||= 1;

    $self->{step} -= $back;

    return $self->redirect;
}

# переходим к следующему дейтсвию в цепочке согласно его пожеланию
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

# копируем stash из Catalyst в Wizard
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
