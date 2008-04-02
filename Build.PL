use strict;
use Module::Build;

my $build = Module::Build->new(
    license             => 'perl',
    module_name         => 'Catalyst::Plugin::Wizard',
    requires            => {
        'perl'                          => 5.006,
        'Catalyst'                      => 0.57,
        'Catalyst::Plugin::Session'     => 0.19,
	'Clone'				=> undef,
    },
    build_requires      => {
        'ok'						=>  0,
        'Test::More'					=>  0,
	'Test::WWW::Mechanize::Catalyst'		=>  0,
	'Catalyst::Plugin::Session::State::Cookie'	=>  0,
    },
    create_makefile_pl  => 'traditional',
    dist_abstract       => 'Catalyst::Plugin::Wizard -- Catalyst module for building wizards',
);

$build->create_build_script;
