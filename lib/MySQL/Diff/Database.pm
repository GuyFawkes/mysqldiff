package MySQL::Diff::Database;

=head1 NAME

MySQL::Diff::Database - Database Definition Class

=head1 SYNOPSIS

  use MySQL::Diff::Database;

  my $db = MySQL::Diff::Database->new(%options);
  my $source    = $db->source_type();
  my $summary   = $db->summary();
  my $name      = $db->name();
  my @tables    = $db->tables();
  my $table_def = $db->table_by_name($table);

  my @dbs = MySQL::Diff::Database::available_dbs();

=head1 DESCRIPTION

Parses a database definition into component parts.

=cut

use warnings;
use strict;

our $VERSION = '0.52';

# ------------------------------------------------------------------------------
# Libraries

use Carp qw(:DEFAULT);
use File::Slurp;
use IO::File;
use DBI;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex);
use version;

use MySQL::Diff::Utils qw(debug get_save_quotes write_log get_logdir generate_random_string);
use MySQL::Diff::Table;
use MySQL::Diff::View;
use MySQL::Diff::Routine;

# ------------------------------------------------------------------------------

=head1 METHODS

=head2 Constructor

=over 4

=item new( %options )

Instantiate the objects, providing the command line options for database
access and process requirements.

=back

=cut

sub new {
    my $class = shift;
    my %p = @_;
    my $self = {};
    bless $self, ref $class || $class;

    debug(1,"\nconstructing new MySQL::Diff::Database");

    my $string = _auth_args_string(%{$p{auth}});
    my $default_params;
    $default_params->{host} = 'localhost';
    $default_params->{port} = '3306';
    for my $arg (qw/host port user password socket/) {
        if ($p{auth}{$arg}) {
            $self->{auth_data}{$arg} = $p{auth}{$arg};
        } else {
            if ($default_params->{$arg}) {
                $self->{auth_data}{$arg} = $default_params->{$arg};
            }
        }
    }
    debug(1,"auth args: $string");
    $self->{_source}{auth} = $string;
    $self->{_source}{dbh} = $p{dbh} if($p{dbh});

    if ($p{file}) {
        debug(1, "Started to canonicalise file ".$p{file});
        $self->_canonicalise_file($p{file});
    } elsif ($p{db}) {
        debug(1, "Started to read db ".$p{db});
        $self->_read_db($p{db});
    } else {
        confess "MySQL::Diff::Database::new called without db or file params";
    }

    debug(1, "Started to parse defs");
    $self->_parse_defs();
    return $self;
}

=head2 Public Methods

=over 4

=item * source_type()

Returns 'file' if the data source is a text file, and 'db' if connected
directly to a database.

=cut

sub source_type {
    my $self = shift;
    return 'file' if $self->{_source}{file};
    return 'db'   if $self->{_source}{db};
}

=item * summary()

Provides a summary of the database.

=cut

sub summary {
    my $self = shift;
  
    if ($self->{_source}{file}) {
        return "file: " . $self->{_source}{file};
    } elsif ($self->{_source}{db}) {
        my $args = $self->{_source}{auth};
        $args =~ tr/-//d;
        $args =~ s/\bpassword=\S+//;
        $args =~ s/^\s*(.*?)\s*$/$1/;
        my $summary = "  db: " . $self->{_source}{db};
        $summary .= " ($args)" if $args;
        return $summary;
    } else {
        return 'unknown';
    }
}

=item * name()

Returns the name of the database.

=cut

sub name {
    my $self = shift;
    return $self->{_source}{file} || $self->{_source}{db};
}

=item * tables()

Returns a list of tables for the current database.

=cut

sub tables {
    my $self = shift;
    return @{$self->{_tables}};
}

=item * views()

Returns a list of views for the current database

=cut
sub views {
    my $self = shift;
    return @{$self->{_views}};
}

=item * routines()

Returns a list of routines for the current database

=cut
sub routines {
    my $self = shift;
    return @{$self->{_routines}};
}

=item * table_by_name( $name )

Returns the table definition (see L<MySQL::Diff::Table>) for the given table.

=cut

sub table_by_name {
    my ($self,$name) = @_;
    return $self->{_by_name}{$name};
}

=item * view_temp( $name )

Returns the temporary table definition (see L<MySQL::Diff::Table>) for the given view.

=cut

sub view_temp {
    my ($self,$name) = @_;
    return $self->{_temp_view_tables}{$name} || '';
}

=item * view_by_name( $name )

Returns the view definitions (see L<MySQL::Diff:View>) for the given view

=cut

sub view_by_name {
    my ($self,$name) = @_;
    return $self->{v_by_name}{$name};
}

=item * routine_by_name( $name )

Returns the routine definitions (see L<MySQL::Diff:Routine>) for the given routine name

=cut

sub routine_by_name {
    my ($self,$name,$type) = @_;
    # epic fail: before i try to get it as $self->{r_by_name}{$name}{$type}; 
    return $self->{r_by_name}{$type}{$name};
}

=item * get_order( $type )

Returns sorting order for entities of type $type (tables, views or routines)

=cut

sub get_order {
    my ($self, $type) = @_;
    my $k = $type."_order";
    return $self->{$k};
}

=back

=head1 FUNCTIONS

=head2 Public Functions

=over 4

=item * available_dbs()

Returns a list of the available databases.

Note that is used as a function call, not a method call.

=cut

sub available_dbs {
    debug(1, "Started to get available databases list");
    my %auth = @_;
    my $args = _auth_args_string(%auth);
  
    # evil but we don't use DBI because I don't want to implement -p properly
    # not that this works with -p anyway ...
    my $fh = IO::File->new("mysqlshow$args |") or die "Couldn't execute 'mysqlshow$args': $!\n";
    my @dbs;
    while (<$fh>) {
        next unless /^\| ([\S]+)/;
        push @dbs, $1;
    }
    $fh->close() or die "mysqlshow$args failed: $!";

    return map { $_ => 1 } @dbs;
}

=back

=cut

# ------------------------------------------------------------------------------
# Private Methods

sub _canonicalise_file {
    my ($self, $file) = @_;

    $self->{_source}{file} = $file;
    debug(1,"fetching table defs from file $file");

    # FIXME: option to avoid create-and-dump bit
    # create a temporary database using defs from file ...
    # hopefully the temp db is unique!
    my $temp_db = sprintf "test_mysqldiff-temp-%d_%d_%d", time(), $$, rand();
    debug(1,"creating temporary database $temp_db");
  
    my $defs = read_file($file);
    die "$file contains dangerous command '$1'; aborting.\n"
        if $defs =~ /;\s*(use|((drop|create)\s+database))\b/i;
  
    my $args = $self->{_source}{auth};
    my $fh = IO::File->new("| mysql $args") or die "Couldn't execute 'mysql$args': $!\n";
    print $fh "\nCREATE DATABASE \`$temp_db\`;\nUSE \`$temp_db\`;\n";
    print $fh $defs;
    $fh->close;

    # ... and then retrieve defs from mysqldump.  Hence we've used
    # MySQL to massage the defs file into canonical form.
    $self->_get_defs($temp_db);

    debug(1,"dropping temporary database $temp_db");
    $fh = IO::File->new("| mysql $args") or die "Couldn't execute 'mysql$args': $!\n";
    print $fh "DROP DATABASE \`$temp_db\`;\n";
    $fh->close;
}

sub _read_db {
    my ($self, $db) = @_;
    $self->{_source}{db} = $db;
    # store database name, if it's not temporary database
    $self->{db_name} = $db;
    debug(1, "fetching table defs from db $db");
    $self->_get_defs($db);
}

sub _get_defs {
    my ($self, $db) = @_;

    my $args = $self->{_source}{auth};
    my $start_time = time();
    my $dump_errors_folder = get_logdir() . '/' . 'dump_errors_' . $db;
    mkdir $dump_errors_folder;
    my $errors_fname =  $dump_errors_folder . '/dump_errors_' . time(). '_' . generate_random_string() . '.log';
    my $need_gtid = 0;
    if (!$self->{db_name}) {
        $self->{temp_db_name} = $db;
    }
    else {
        my $dsn = "DBI:mysql:$self->{db_name}:$self->{auth_data}{host}";
        my $db_user_name = $self->{auth_data}{user};
        my $db_password = $self->{auth_data}{password};
        my $errcb = sub {     
            my $message = shift;
            print "Error from DBI while fetching differences:\n";
            if ($DBI::lasth->{Statement}) {
                print $DBI::lasth->{Statement} . "\n";
            }
            print DBI->errstr. "\n";
            print "mysqldiff cannot get diff because of this error\n";
            exit(1);  
        };
        my $dbh = DBI->connect($dsn, $db_user_name, $db_password, {
            PrintError  => 0,
            HandleError => \&$errcb,
        }) or errcb(DBI->errstr);
        my $sth = $dbh->prepare(qq{SHOW VARIABLES WHERE `Variable_name` = 'GTID_MODE';});
        $sth->execute();
        while (my @row = $sth->fetchrow_array()) {
            $need_gtid = 1;
        }
        $sth->finish();
        $dbh->disconnect();
    }
    my $gtid_option = 0;
    my $mysqldump_version = `mysqldump --version`;
    if ($mysqldump_version =~ m/Distrib\s([\d.]+)/) {
        my $v1 = version->parse('5.6.9');
        my $v2 = version->parse($1);
        if ($v2 >= $v1) {
            $gtid_option = 1;
        }
    }
    my $mysqldump_cmd = "mysqldump -d -q --force --skip-lock-tables --skip-triggers";
    if ($gtid_option) {
        if ($need_gtid) {
            $mysqldump_cmd .= ' --set-gtid-purged=AUTO';
        }
        else {
            $mysqldump_cmd .= ' --set-gtid-purged=OFF';
        }
    }
    my $fh = IO::File->new("$mysqldump_cmd $args $db 2>$errors_fname |")
        or die "Couldn't read ${db}'s table defs via mysqldump: $!\n";
    debug(6, "running mysqldump -d $args $db");
    my $defs = $self->{_defs} = [ <$fh> ];
    $fh->close;
    open(DUMP_ERRS, "<$errors_fname");
    my(@errs_lines) = <DUMP_ERRS>;
    debug(6, "dump time: ".(time() - $start_time));
    if (grep /mysqldump: Got error: .*: Unknown database/, @errs_lines) {
        die <<EOF;
Failed to create temporary database $db
during canonicalization.  Make sure that your mysql.db table has a row
authorizing full access to all databases matching 'test\\_%', and that
the database doesn't already exist.
EOF
    }
    if (@errs_lines && !grep /Using a password on the command line interface can be insecure/, @errs_lines) {
        print "Errors from mysqldump:\n";
        print "@errs_lines";
        print "mysqldiff cannot get diff because of this errors\n";
        exit(1); 
    }
    close (DUMP_ERRS);
}

sub _parse_defs {
    my $self = shift;

    return if $self->{_tables};

    debug(1, "parsing tables defs");
    my $defs = join '', @{$self->{_defs}};
    my $routines_defs = '';
    my $c = get_save_quotes();
    if (!$c) {
        $defs =~ s/`//sg;
    }
    
    my $db_log = '';
    my $dbh;
    if ($self->{db_name}) {
        $db_log = $self->{db_name};
    } else {
        $db_log = $self->{temp_db_name};
    }
    write_log('defs_before_'.$db_log.'.sql', $defs);
    $defs =~ s/^(\#|--).*?$//gim; # delete singleline comments
    $defs =~ s/\/\*\!\d+\s+SET\s+.*?;\s*//ig; # delete SETs
    $defs =~ s/\/\*\!\d+\s+(.*?)\*\//\n$1/gs; # get content from executable comments
    $defs =~ s/\/\*.*?\*\/\s*//gs; #delete all multiline comments
    
    # initialize structures here
    $self->{_tables} = [];
    $self->{_views} = [];
    $self->{_routines} = [];
    my $counters;
    $counters->{tables} = 0;
    $counters->{views} = 0;
    $counters->{routines} = 0;
    
    if ($self->{db_name}) {
        my $dsn = "DBI:mysql:$self->{db_name}:$self->{auth_data}{host}";
        my $db_user_name = $self->{auth_data}{user};
        my $db_password = $self->{auth_data}{password};
        my $errcb = sub {     
            my $message = shift;
            print "Error from DBI while parsing differences:\n";
            print $DBI::lasth->{Statement} . "\n";
            print DBI->errstr. "\n";
            print "mysqldiff cannot get diff because of this error\n";
            exit(1);  
        };
        $dbh = DBI->connect($dsn, $db_user_name, $db_password, {
            PrintError  => 0,
            HandleError => \&$errcb,
        }) or errcb(DBI->errstr);
        $dbh->do(qq{SET NAMES 'utf8';});
        # TODO: refactoring
        # get triggers
        my $sth = $dbh->prepare(qq{SHOW TRIGGERS});
        $sth->execute();
        my @triggers_list = ();
        while (my @row = $sth->fetchrow_array()) {
            push(@triggers_list, $row[0]);
        }
        $sth->finish();
        # get procedures
        $sth = $dbh->prepare(qq{SHOW PROCEDURE STATUS WHERE Db='$self->{db_name}'});
        $sth->execute();
        my @procedures_list = ();
        while (my @row = $sth->fetchrow_array()) {
            push(@procedures_list, $row[1]);
        }    
        $sth->finish();
        # get functions
        $sth = $dbh->prepare(qq{SHOW FUNCTION STATUS WHERE Db='$self->{db_name}'});
        $sth->execute();
        my @functions_list = ();
        while (my @row = $sth->fetchrow_array()) {
            push(@functions_list, $row[1]);
        }    
        $sth->finish();
        my $routines_list;
        $routines_list->{TRIGGER} = [@triggers_list];
        $routines_list->{PROCEDURE} = [@procedures_list];
        $routines_list->{FUNCTION}= [@functions_list];
        for my $entity (keys %$routines_list) {
            my @routines_sublist = @{$routines_list->{$entity}};
            if (@routines_sublist) {
                foreach (@routines_sublist) {
                    my $s = qq{SHOW CREATE $entity $_};
                    $sth = $dbh->prepare($s);
                    $sth->execute();
                    my @row = $sth->fetchrow_array();
                    # $row[2] contains text of routine
                    if (defined $row[2]) {
                        # concatenate text to write it to log file after with text of tables and views
                        $routines_defs .= "\n$row[2]";
                        my $obj = MySQL::Diff::Routine->new(source => $self->{_source}, def => $row[2]);
                        $self->{r_by_name}{$obj->type()}{$obj->name()} = $obj;
                        $self->{routines_order}{$obj->name()} = $counters->{routines};
                        $counters->{routines} += 1;
                        push @{$self->{_routines}}, $obj;
                    }
                    $sth->finish();
                }
            }
        }
    }

    write_log('defs_after_'.$db_log.'.sql', $defs . "\n" . $routines_defs);

    my @tables = split /(?=^\s*(?:create|alter|drop)\s+(?:table|.*?view)\s+)/ims, $defs;
    for my $table (@tables) {
        debug(5, "  table def [$table]");
        if($table =~ /create\s+table\s+/i) {
            my $obj = MySQL::Diff::Table->new(source => $self->{_source}, def => $table);
            $self->{_by_name}{$obj->name()} = $obj;
            $self->{tables_order}{$obj->name()} = $counters->{tables};
            $counters->{tables} += 1;
        } 
        elsif ($table =~ /create\s+.*?\s+view\s+/is) {
            my $obj = MySQL::Diff::View->new(source => $self->{_source}, def => $table);
            $self->{v_by_name}{$obj->name()} = $obj;
            if ($self->{_by_name}{$obj->name()}) {
                $self->{_temp_view_tables}{$obj->name()} = 1;
                delete($self->{_by_name}{$obj->name()});
            }
            $self->{views_order}{$obj->name()} = $counters->{views};
            $counters->{views} += 1;
        }
    }
    if ($self->{db_name}) {
            my $sth;
            my $fields_s = '';
            for my $temp_table (keys %{$self->{_temp_view_tables}}) {
                $sth = $dbh->prepare(qq{SHOW FIELDS FROM $temp_table});
                $sth->execute();
                my @f_list = ();
                while (my @row = $sth->fetchrow_array()) {
                        # push concatenated string consists of field name and type
                        push(@f_list, $row[0].' '.$row[1]);
                }
                $sth->finish();
                $fields_s = join ', ', @f_list;
                $self->{_temp_view_tables}{$temp_table} = "CREATE TABLE $temp_table ($fields_s);"; 
            }
            $dbh->disconnect();
    }
    for my $t (keys %{$self->{_by_name}}) {
        push @{$self->{_tables}}, $self->{_by_name}{$t};
    }
    for my $v (keys %{$self->{v_by_name}}) {
        push @{$self->{_views}}, $self->{v_by_name}{$v};
    }
}

sub _auth_args_string {
    my %auth = @_;
    my $args = '';
    for my $arg (qw/host port user password socket/) {
        $args .= " --$arg=$auth{$arg}" if $auth{$arg};
    }
    return $args;
}

1;

__END__

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2000-2011 Adam Spiers. All rights reserved. This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<mysqldiff>, L<MySQL::Diff>, L<MySQL::Diff::Table>, L<MySQL::Diff::Utils>

=head1 AUTHOR

Adam Spiers <mysqldiff@adamspiers.org>

=cut
