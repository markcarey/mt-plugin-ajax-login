use ExtUtils::MakeMaker;

use YAML::Any qw(LoadFile);
my $file = "plugins/AJAXLogin/config.yaml";
my $version = LoadFile($file)->{version} ||
    die "No version found in $file";

WriteMakefile(
    NAME            => 'AJAX Login',
    VERSION         => $version,
    DISTNAME        => 'AJAX Login',
);
