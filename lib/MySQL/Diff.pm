package MySQL::Diff;

=head1 NAME

MySQL::Diff - Generates a database upgrade instruction set

=head1 SYNOPSIS

  use MySQL::Diff;

  my $md = MySQL::Diff->new( %options );
  my $db1 = $md->register_db($ARGV[0], 1);
  my $db2 = $md->register_db($ARGV[1], 2);
  my $diffs = $md->diff();

=head1 DESCRIPTION

Generates the SQL instructions required to upgrade the first database to match
the second.

=cut

use warnings;

our $VERSION = '0.51';

# ------------------------------------------------------------------------------
# Libraries

use MySQL::Diff::Database;
use MySQL::Diff::Utils qw(debug debug_level debug_file set_save_quotes save_logdir write_log generate_random_string);

use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex);
use FindBin;

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
    my %hash  = @_;
    my $self = {};
    bless $self, ref $class || $class;

    $self->{opts} = \%hash;
    
    if($hash{debug})        { debug_level($hash{debug})     ; delete $hash{debug};      }
    if($hash{debug_file})   { debug_file($hash{debug_file}) ; delete $hash{debug_file}; }
    
    if ($hash{'save-quotes'}) {
        set_save_quotes($hash{'save-quotes'});
    }

    debug(1,"\nconstructing new MySQL::Diff");

    my $dir_path = '';
    if ($hash{'logs-folder'}) {
        $dir_path = $hash{'logs-folder'};
    } else {
        $dir_path = $FindBin::RealBin.'/logs';
    }

    if (!-d $dir_path) {
        my $tdir;
        my $accum = '';
        my $ret;
        foreach $tdir (split(/\//, $dir_path)){
            $accum = "$accum$tdir/";
            if($tdir ne ""){
                if(!-d "$accum"){
                    $ret = mkdir $accum, 0777;
                    if (!$ret) {
                        print "Cannot create directory $accum: $!\n";
                        exit(1);
                    }
                }
            }
        }
    }
    save_logdir($dir_path);

    return $self;
}

=head2 Public Methods

Fuller documentation will appear here in time :)

=over 4

=item * register_db($name,$inx)

Reference the database, and setup a connection. The name can be an already
existing 'MySQL::Diff::Database' database object. The index can be '1' or '2',
and refers both to the order of the diff, and to the host, port, username and
password arguments that have been supplied.

=cut

sub register_db {
    my ($self, $name, $inx) = @_;
    debug(1, "Register database $name as # $inx");
    return unless $inx == 1 || $inx == 2;

    my $db = ref $name eq 'MySQL::Diff::Database' ? $name : $self->_load_database($name,$inx);
    $self->{databases}[$inx-1] = $db;
    return $db;
}

=item * db1()

=item * db2()

Return the first and second databases registered via C<register_db()>.

=cut

sub db1 { shift->{databases}->[0] }
sub db2 { shift->{databases}->[1] }

=item * diff()

Performs the diff, returning a string containing the commands needed to change
the schema of the first database into that of the second.

=back

=cut

sub diff {
    my $self = shift;
    my $table_re = $self->{opts}{'table-re'};
    my @changes;

    debug(1, "\ncomparing databases");

    my $tables_order = $self->db1->get_order('tables');
    my $views_order = $self->db1->get_order('views');
    my $routines_order = $self->db1->get_order('routines');
    my @tables_keys = sort { $tables_order->{$a->name()} <=> $tables_order->{$b->name()} } $self->db1->tables();
    my @views_keys = sort { $views_order->{$a->name()} <=> $views_order->{$b->name()} } $self->db1->views();
    my @routines_keys = sort { $routines_order->{$a->name()} <=> $routines_order->{$b->name()} } $self->db1->routines();

    # workaround temporary procedure for indexes with same name as FK
    $self->{index_wa} = {};
    my $index_wa_name = 'workaround_' . generate_random_string();
    my $index_wa_sql = '@sqlstmt';
    $self->{index_wa}{'create-stmt'} = <<CREATE_STMT;
DELIMITER ;;

CREATE PROCEDURE `$index_wa_name`
(
    given_table    VARCHAR(64),
    given_index    VARCHAR(64),
    index_stmt     TEXT,
    index_action   VARCHAR(10)
)
BEGIN

    DECLARE IndexIsThere INTEGER;

    SELECT COUNT(1) INTO IndexIsThere
    FROM INFORMATION_SCHEMA.STATISTICS
    WHERE table_schema = DATABASE() 
    AND   table_name   = given_table
    AND   index_name   = given_index;

    IF (IndexIsThere >= 1 AND index_action = 'drop') OR (IndexIsThere = 0 AND index_action = 'create') THEN
        SET $index_wa_sql = index_stmt;
        PREPARE st FROM $index_wa_sql;
        EXECUTE st;
        DEALLOCATE PREPARE st;
    END IF;

END ;;

DELIMITER ;
CREATE_STMT

    $self->{index_wa}{'drop-stmt'} = "DROP PROCEDURE `$index_wa_name`;\n";
    $self->{index_wa}{'name'} = $index_wa_name;
    $self->{index_wa}{'used'} = 0;

    for my $table1 (@tables_keys) {
        my $name = $table1->name();
        debug(1, "looking at table '$name' in first database");
        debug(6, "table 1 $name = ".Dumper($table1));
        if ($table_re && $name !~ $table_re) {
            debug(5,"table '$name' didn't match /$table_re/; ignoring");
            next;
        }
        if (!$self->{opts}{'refs'}) {
            $self->{'used_tables'}{$name} = 1;       
            if (my $table2 = $self->db2->table_by_name($name)) {
                debug(1,"comparing tables called '$name'");
                push @changes, $self->_diff_tables($table1, $table2);
            } else {
                $view_exists = $self->db2->view_by_name($name) ? 1 : 0;
                if ($view_exists) {
                    debug(1, "table '$name' is not exists in second database, but there is view with same name");
                }
                else {
                    debug(1,"table '$name' dropped");
                    my $change = '';
                    $change = $self->add_header($table1, "drop_table") unless !$self->{opts}{'list-tables'};
                    $change .= "DROP TABLE $name;\n\n";
                    push @changes, [$change, {'k' => 8}]                 
                        unless $self->{opts}{'only-both'} || $self->{opts}{'keep-old-tables'}; # drop table after all
                }
            }
        } else {
            if (!$self->{'used_tables'}{$name}) {
                $self->{'used_tables'}{$name} = 1;
                my $additional_tables = '';
                my $additional_fk_tables = $table1->fk_tables();
                if ($additional_fk_tables) {
                    push @changes, $self->_add_ref_tables($additional_fk_tables);
                }
                my $change = '';
                $change = $self->add_header($table1, "ref_table", 1);
                push @changes, [$change, {'k' => 1}];
            }
        }
    }

    for my $routine1 (@routines_keys) {
        my $name = $routine1->name();
        my $r_type = $routine1->type();
        debug(1, "loooking at $r_type '$name' in first database");
        if (!$self->{opts}{'refs'}) {
            if (my $routine2 = $self->db2->routine_by_name($name, $r_type)) {
                debug(1, "Comparing ". $r_type . "s called '$name'");
                my $r_opts1 = $routine1->options();
                my $r_opts2 = $routine2->options();
                my $r_body1 = $routine1->body();
                my $r_body2 = $routine2->body();
                my $r_pars1 = $routine1->params();
                my $r_pars2 = $routine2->params();
                if ( ($r_opts1 ne $r_opts2) || ($r_body1 ne $r_body2) || ($r_pars1 ne $r_pars2) ) {
                    write_log($r_type.'_'.$name.'.sql', "Options 1: $r_opts1\nOptions 2: $r_opts2\nBody 1: $r_body1\nBody 2: $r_body2\nParams 1: $r_pars1\nParams 2: $r_pars2");
                    my $change = $self->add_header($routine1, "change_routine") unless !$self->{opts}{'list-tables'};
                    $change .= "DROP $r_type IF EXISTS $name;\n";
                    $change .= "DELIMITER ;;\n";
                    $change .= $routine2->def() . ";;\n";
                    $change .= "DELIMITER ;\n";
                    push @changes, [$change, {'k' => 5}]                 
                            unless $self->{opts}{'only-both'} || $self->{opts}{'keep-old-tables'}; 
                }
            } else {
                debug(1, "$r_type '$name' dropped;");
                my $change = '';
                $change = $self->add_header($routine1, "drop_routine") unless !$self->{opts}{'list-tables'};
                $change .= "DROP $r_type IF EXISTS $name;\n";
                push @changes, [$change, {'k' => 5}]                 
                         unless $self->{opts}{'only-both'} || $self->{opts}{'keep-old-tables'}; 
            }
        }
    }

    for my $view1 (@views_keys) {
        my $name = $view1->name();
        debug(1, "looking at view '$name' in first database");
        if (!$self->{opts}{'refs'}) {
                if (my $view2 = $self->db2->view_by_name($name)) {
                    debug(1, "Comparing views called '$name'");
                    my $f1 = $view1->fields();
                    my $f2 = $view2->fields();
                    my $sel1 = $view1->select();
                    my $sel2 = $view2->select();
                    my $opts1 = $view1->options();
                    my $opts2 = $view2->options();

                    if ( ($f1 ne $f2) || 
                         ($sel1 ne $sel2) || 
                         ($opts1->{'security'} ne $opts2->{'security'}) || 
                         ($opts1->{'trail'} ne $opts2->{'trail'}) || 
                         ($opts1->{'algorithm'} ne $opts2->{'algorithm'}) 
                       ) {
                        my $change = '';
                        $change = $self->add_header($view1, "change_view") unless !$self->{opts}{'list-tables'};
                        $change .= "ALTER ALGORITHM=$opts2->{'algorithm'} DEFINER=CURRENT_USER SQL SECURITY $opts2->{'security'} VIEW $name $f2 AS ($sel2) $opts2->{'trail'};\n";
                        push @changes, [$change, {'k' => 5}]                 
                            unless $self->{opts}{'only-both'} || $self->{opts}{'keep-old-tables'}; 
                    }
                } else {
                    debug(1, "view '$name' dropped");
                    my $change = '';
                    $change = $self->add_header($view1, "drop_view") unless !$self->{opts}{'list-tables'};
                    $change .= "DROP VIEW $name;\n\n";
                    push @changes, [$change, {'k' => 6}]                 
                         unless $self->{opts}{'only-both'} || $self->{opts}{'keep-old-tables'}; 
                }
        }
    }

    if (!$self->{opts}{'refs'}) {
        $tables_order = $self->db2->get_order('tables');
        $views_order = $self->db2->get_order('views');
        $routines_order = $self->db2->get_order('routines');
        @tables_keys = sort { $tables_order->{$a->name()} <=> $tables_order->{$b->name()} } $self->db2->tables();
        @views_keys = sort { $views_order->{$a->name()} <=> $views_order->{$b->name()} } $self->db2->views();
        @routines_keys = sort { $routines_order->{$a->name()} <=> $routines_order->{$b->name()} } $self->db2->routines();
        for my $table2 (@tables_keys) {
            my $name = $table2->name();
            debug(1, "looking at table '$name' in second database");
            debug(6, "table 2 $name = ".Dumper($table2));
            if ($table_re && $name !~ $table_re) {
                debug(5,"table '$name' matched $self->{opts}{'table-re'}; ignoring");
                next;
            }
            if (! $self->db1->table_by_name($name) && ! $self->{'used_tables'}{$name}) {
                $self->{'used_tables'}{$name} = 1;
                debug(1, "table '$name' added to diff");
                debug(2, "definition of '$name': ".$table2->def());
                my $additional_tables = '';
                my $additional_fk_tables = $table2->fk_tables();
                if ($additional_fk_tables) {
                    push @changes, $self->_add_ref_tables($additional_fk_tables, $name);
                }
                my $change = '';
                $change = $self->add_header($table2, "add_table", 1) unless !$self->{opts}{'list-tables'};
                $change .= $table2->def() . "\n";
                push @changes, [$change, {'k' => 6}]
                    unless $self->{opts}{'only-both'};
                if (!$self->{opts}{'only-both'}) {
                    my $fks = $table2->foreign_key();
                    for my $fk (keys %$fks) {
                        debug(3, "FK $fk for created table $name added");
                        $change = '';
                        $change = $self->add_header($table2, 'add_fk') unless !$self->{opts}{'list-tables'};
                        $change .= "ALTER TABLE $name ADD CONSTRAINT $fk FOREIGN KEY $fks->{$fk};\n";
                        push @changes, [$change, {'k' => 1}];
                    }
                }
            }
        }
        for my $routine2 (@routines_keys) {
            my $name = $routine2->name();
            my $r_type = $routine2->type();
            debug(1, "looking at $r_type '$name' in second database");
            if (!$self->db1->routine_by_name($name, $r_type)) {
                my $change = '';
                $change = $self->add_header($routine2, "add_routine") unless !$self->{opts}{'list-tables'};
                $change .= "DELIMITER ;;\n";
                $change .= $routine2->def(). ";;\n";
                $change .= "DELIMITER ;\n";
                push @changes, [$change, {'k' => 5}]
                    unless $self->{opts}{'only-both'};
            }
        }
        for my $view2 (@views_keys) {
            my $name = $view2->name();
            debug(1, "looking at view '$name' in second database");
            if (!$self->db1->view_by_name($name)) {
                my $change = '';
                my $temp_view = '';
                debug(2, "looking for temporary table for view '$name'");
                $temp_view = $self->add_header($name.'_temptable', "add_table", 0, 1) unless !$self->{opts}{'list-tables'};
                $temp_view .= "DROP TABLE IF EXISTS $name;\n" . $self->db2->view_temp($name) . "\n";
                push @changes, [$temp_view, {'k' => 9}] 
                    unless $self->{opts}{'only-both'};    
                $change = $self->add_header($view2, "add_view") unless !$self->{opts}{'list-tables'};
                $change .= "DROP TABLE IF EXISTS $name;\n" . $view2->def() . "\n";
                push @changes, [$change, {'k' => 5}]
                    unless $self->{opts}{'only-both'};
            }
        }
    }

    debug(4, Dumper(@changes));

    my $out = '';
    if (@changes) {
        if (!$self->{opts}{'list-tables'} && !$self->{opts}{'refs'}) {
            $out .= $self->_diff_banner();
        }
        my @sorted = sort { return $b->[1]->{'k'} cmp $a->[1]->{'k'} } @changes;
        my $column_index = 0;
        my $line = join '', map $_->[$column_index], @sorted;
        my $wa_name = $self->{index_wa}{'name'};
        if ($self->{index_wa}{'used'}) {
            $out .= $self->add_header($wa_name . '_create', 'create_workaround', 0, 1);
            $out .= $self->{index_wa}{'create-stmt'};
        }
        $out .= $line;
        if ($self->{index_wa}{'used'}) {
            $out .= $self->add_header($wa_name . '_drop', 'drop_workaround', 0, 1);
            $out .= $self->{index_wa}{'drop-stmt'};
        }
    }
    return $out;
}

# ------------------------------------------------------------------------------
# Private Methods

sub _add_ref_tables {
    my ($self, $tables, $refed) = @_;
    my @changes = ();
    if ($tables) {
        for my $name (keys %$tables) {
            if (!$self->{'used_tables'}{$name}) {
                $self->{'used_tables'}{$name} = 1;
                my $table;
                if (!$self->{opts}{'refs'}) {
                    $table = $self->db2->table_by_name($name);
                } else {
                    $table = $self->db1->table_by_name($name);
                }
                if ($table) {
                    debug(2, "Related table: '$name'");
                    my $additional_tables = '';
                    my $additional_fk_tables = $table->fk_tables();
                    if ($additional_fk_tables) {
                            push @changes, $self->_add_ref_tables($additional_fk_tables);
                    }
                    my $change = '';
                    if (!$self->{opts}{'refs'}) {
                        $change = $self->add_header($table, "add_table", 1) unless !$self->{opts}{'list-tables'};
                        $change .= $table->def()."\n";
                    } else {
                        $change = $self->add_header($table, "ref_table", 1) . "\n";
                    }
                    push @changes, [$change, {'k' => 6}];
                    if (!$self->{opts}{'refs'}) {
                        if (!$self->{opts}{'only-both'}) {
                            my $fks = $table->foreign_key();
                            for my $fk (keys %$fks) {
                                debug(3, "FK $fk for created table $name added");
                                $change = '';
                                $change = $self->add_header($table, 'add_fk') unless !$self->{opts}{'list-tables'};
                                $change .= "ALTER TABLE $name ADD CONSTRAINT $fk FOREIGN KEY $fks->{$fk};\n";
                                push @changes, [$change, {'k' => 1}];
                            }
                        }
                    }
                }
            }
        }
    }
    return @changes;
}


sub _diff_banner {
    my ($self) = @_;

    my $summary1 = $self->db1->summary();
    my $summary2 = $self->db2->summary();

    my $opt_text =
        join ', ',
            map { $self->{opts}{$_} eq '1' ? $_ : "$_=$self->{opts}{$_}" }
                keys %{$self->{opts}};
    $opt_text = "## Options: $opt_text\n" if $opt_text;

    my $now = scalar localtime();
    return <<EOF;
## mysqldiff $VERSION
## 
## Run on $now
$opt_text##
## --- $summary1
## +++ $summary2

EOF
}

sub _diff_tables {
    my $self = shift;
    $self->{changed_pk_auto_col} = 0;
    $self->{added_pk} = 0;
    $self->{added_pk_col} = 0;
    $self->{dropped_columns} = {};
    $self->{changed_to_empty_char_col} = {};
    $self->{changed_for_fk} = {};
    $self->{added_index} = {};
    $self->{added_for_fk} = {};
    $self->{fk_for_pk} = {};
    $self->{temporary_indexes} = {};
    $self->{added_cols} = {};
    $self->{timestamps} = {};
    my @changes = $self->_diff_fields(@_);
    push @changes, $self->_diff_indices(@_);
    push @changes, $self->_diff_primary_key(@_);
    push @changes, $self->_diff_foreign_key(@_);
    push @changes, $self->_diff_options(@_);    

    $changes[-1][0] =~ s/\n*$/\n/  if (@changes);
    return @changes;
}

sub _diff_fields {
    my ($self, $table1, $table2) = @_;

    my $name1 = $table1->name();

    my $fields1 = $table1->fields;
    my $fields2 = $table2->fields;

    return () unless $fields1 || $fields2;

    my @changes;

    # parts of primary key in table 2
    my $pp = $table2->primary_parts();
    # size of parts (1 in case key is non-composite)
    my $size = scalar keys %$pp; 
    my $diff_hash = {};
    # get columns from primary key parts that not presented in table1's fields list (it will be added)
    foreach (keys %$pp) {
        $diff_hash->{$_} = $pp->{$_} if !exists($fields1->{$_});
    }
    # get list of diff fields sorted on the basis of availability AUTO_INCREMENT clause to get last PK's field
    my $f_last;
    my @d_keys;
    if (keys %$diff_hash) {
        @d_keys = sort { ($fields2->{$a}=~/\s*AUTO_INCREMENT\s*/is) cmp ($fields2->{$b}=~/\s*AUTO_INCREMENT\s*/is)} keys %$diff_hash;
    } else {
        @d_keys = sort { ($fields2->{$a}=~/\s*AUTO_INCREMENT\s*/is) cmp ($fields2->{$b}=~/\s*AUTO_INCREMENT\s*/is)} keys %$pp;
    }
    $f_last = (@d_keys)[-1];
    debug(3, "Last PK: $f_last") if ($f_last);

    if($fields1) {
        # get list of table1's fields sorted on the basis of availability AUTO_INCREMENT clause IN TABLE 2 and, then, on PROPERLY order of fields
        my $order1 = $table1->fields_order();
        my @keys = sort { 
            (
                ($fields2 && $fields2->{$a} && $fields2->{$b}) &&
                (
                        ($fields2->{$a}=~/\s*AUTO_INCREMENT\s*/is) cmp 
                        ($fields2->{$b}=~/\s*AUTO_INCREMENT\s*/is)
                )
            ) 
            || 
            ($order1->{$a} <=> $order1->{$b})
        } keys %$fields1;
        my $alters;
        for my $field (@keys) {
            debug(2, "$name1 had field '$field'");
            my $f1 = $fields1->{$field};
            my $f2 = $fields2->{$field};
            if ($fields2 && $f2) {
                if ($self->{opts}{tolerant}) {
                    for ($f1, $f2) {
                        s/ COLLATE [\w_]+//gi;
                    }
                }
                if ($f1 ne $f2) {
                    if (not $self->{opts}{tolerant} or 
                        (($f1 !~ m/$f2\(\d+,\d+\)/) and
                         ($f1 ne "$f2 DEFAULT '' NOT NULL") and
                         ($f1 ne "$f2 NOT NULL") ))
                    {
                        debug(3,"field '$field' changed");
                        my $pk = '';
                        my $weight = 5;
                        # if it's PK in second table...
                        if ($table2->isa_primary($field)) {
                            # if some parts of PK will be added later, we must not do any work with PK now
                            if (keys %$diff_hash) {
                                debug(3, "There will be parts of PK that exist only in second table");
                            } else {
                                # otherwise, add PRIMARY KEY clause/operator:
                                # if there wasn't PK, it will be created HERE
                                # if it was, we WILL drop it (in _diff_primary_key) and create again by operator generated here.
                                debug(3, "All parts of PK are exist in both tables");
                                # if it's not PK already (in TABLE 1)
                                if (!$table1->isa_primary($field)) {
                                    if ($size == 1) {
                                        # if PK is non-composite we can to add PRIMARY KEY clause
                                        debug(3, "field $field was changed to be a primary key");
                                        $pk = ' PRIMARY KEY';
                                        $weight = 1;
                                        # Flag we add PK's column(s)
                                        $self->{added_pk} = 1;
                                    } else {
                                        # This way, we can to add PRIMARY KEY __operator__ when last part of PK was obtained
                                        debug(3, "field $field is a part of composite primary key and it was changed");
                                        if ($field eq $f_last) {
                                            debug(3, "field '$field' is a last part of composite primary key, so when it changed, we must to add primary key then");
                                            my $p = $table2->primary_key();
                                            $pk = ", ADD PRIMARY KEY $p";
                                            $weight = 1;
                                            $self->{added_pk} = 1;
                                        }
                                    }
                                } else {
                                    debug(3, "field '$field' is already PK in table 1");
                                    $pk = '';
                                }
                            }
                        } else {
                            if ($table1->isa_primary($field)) {
                                if ($f2 =~ /DEFAULT NULL/is) {
                                    # we must to change this column later, if it was PK in table in first database
                                    # otherwise, it will be not 'DEFAULT NULL', but, for example, for INT column "NOT NULL DEFAULT '0'"
                                    debug(3, "executing DEFAULT NULL change later for field '$field', because it was PK");
                                    $weight = 3;
                                }
                                if ($f1 =~ /AUTO_INCREMENT/is) {
                                    # now we need to just change this column when drop primary key
                                    $self->{changed_pk_auto_col} = 1;
                                    debug(3, "executing DEFAULT NULL change later for field '$field', because it was PK, when PK will be dropped");
                                }
                            }
                        }  
                        # if it will not be PK, but is auto column, set flag, so auto index can be added before column changing
                        if (!$self->{added_pk} && ($f2 =~ /AUTO_INCREMENT/is)) {
                            debug(3, "field $field is auto increment, so we will add index before column changing");
                            $self->{added_index}{field} = $field;
                            $self->{added_index}{is_new} = 0;
                        }
                        my $change = '';
                        if ($f2 =~ /CHAR\s*\(0\)/is) {
                            debug(3, "field $field is changed to CHAR(0)");
                            $self->{changed_to_empty_char_col}{$field}  = $weight;
                        }
                        if (!$self->{changed_pk_auto_col} || ($self->{changed_pk_auto_col} ne 1)) {
                            $change =  $self->add_header($table2, "change_column") unless !$self->{opts}{'list-tables'};
                            $change .= "ALTER TABLE $name1 CHANGE COLUMN $field $field $f2$pk;";
                            $change .= " # was $f1" unless $self->{opts}{'no-old-defs'};
                            $change .= "\n";
                            if ($f2 =~ /(CURRENT_TIMESTAMP(?:\(\))?|NOW\(\)|LOCALTIME(?:\(\))?|LOCALTIMESTAMP(?:\(\))?)/) {
                                $weight = 1;
                            }
                            my $col_fks1 = $table1->get_fk_by_col($field);
                            my $col_fks2 = $table2->get_fk_by_col($field);
                            my $store_fk = 0;
                            if ($col_fks1 && $col_fks2) {
                                for my $col_fk (keys %$col_fks1) {
                                    my $fk1 = $col_fks1->{$col_fk};
                                    my $fk2 = $col_fks2->{$col_fk};
                                    if ($fk2 && ($fk2 ne $fk1)) {
                                        # if there is FK for this column, and it will be changed later,
                                        # we need to store this information for wrapping like:
                                        # 1. DROP FK
                                        # 2. CHANGE COLUMN
                                        # 3. ADD FK
                                        $self->{changed_for_fk}{$col_fk}{$field} = {};
                                        $self->{changed_for_fk}{$col_fk}{$field}{'stmt'} = $change;
                                        $self->{changed_for_fk}{$col_fk}{$field}{'weight'} = $weight;
                                        $store_fk = 1;
                                    }
                                }
                            }
                            if (!$store_fk) {
                                # column must be changed/added first
                                push @changes, [$change, {'k' => $weight}];
                            }
                        } else {
                            $self->{changed_pk_auto_col} = "CHANGE COLUMN $field $field $f2$pk;";
                        }
                    }
                } 
                #else {
                #    if ($table2->isa_primary($field)) {
                #        debug(3, "column '$field' is a PK in second table");
                #        $self->{added_pk} = 1;
                #    }
                #}
            } else {
                debug(3,"field '$field' removed");
                my $change = '';
                $change = $self->add_header($table1, "drop_column") unless !$self->{opts}{'list-tables'};
                $change .= "ALTER TABLE $name1 DROP COLUMN $field;";
                $change .= " # was $fields1->{$field}" unless $self->{opts}{'no-old-defs'};
                $change .= "\n";
                $self->{dropped_columns}{$field} = 1;
                # column must be dropped last
                push @changes, [$change, {'k' => 2}];
            }
        }
    }

    if($fields2) {
        my $order2 = $table2->fields_order();
        # get list of table2's fields sorted on the basis of availability AUTO_INCREMENT clause and, then, with properly order
        my @keys = sort { 
            ($fields2->{$a}=~/\s*AUTO_INCREMENT\s*/is) cmp ($fields2->{$b}=~/\s*AUTO_INCREMENT\s*/is) 
            ||
            ($order2->{$a} <=> $order2->{$b})
        } keys %$fields2;
        my $alters;
        my $after_ts = 0;
        my $weight = 5;
        for my $field (@keys) {
            unless($fields1 && $fields1->{$field}) {
                debug(2,"field '$field' added");
                my $field_links = $table2->fields_links($field);
                my $position = ' FIRST';
                my $prev_field;
                my $prev_field_links;
                if ($field_links->{'prev_field'}) {
                    $prev_field = $field_links->{'prev_field'};
                    $prev_field_links  = $table1->fields_links($prev_field);
                    if (!$prev_field_links) {
                        $prev_field_links = $table2->fields_links($prev_field);
                    }
                    if ($prev_field_links && $prev_field_links->{'next_field'}) {
                        if (!$after_ts) {
                            if ($alters->{$prev_field} && !($table2->isa_primary($prev_field))) {
                                # field before was already added, so it's safe to add current field with AFTER clause
                                $position = " AFTER $prev_field";
                            } else {
                                $alters->{$prev_field} = "ALTER TABLE $name1 CHANGE COLUMN $field $field $fields2->{$field} AFTER $prev_field;\n";
                                $position = '';
                            }
                        } else {
                            $position = '';
                            $after_ts = 0;
                        }
                    } else {
                        # it is last field, so we must not use "after" clause
                        $position = '';   
                    }
                }
                $weight = 5;
                # MySQL condition for timestamp fields
                if ($fields2->{$field} =~ /(CURRENT_TIMESTAMP(?:\(\))?|NOW\(\)|LOCALTIME(?:\(\))?|LOCALTIMESTAMP(?:\(\))?)/) {
                    $self->{timestamps}{$field} = 1;
                    $weight = 1;
                    $alters->{$field} = $self->_add_routine_alters($field, $field_links, $table2);
                    if ($alters->{$field}) {
                        $after_ts = 1;
                        debug(3, "repeat change columns for '$field' after timestamp column");
                    }
                }
                debug(3, "field '$field' added at position: $position") if ($position);
                my $pk = $position;
                my $header_text = 'add_column';
                # if it is PK...
                if ($table2->isa_primary($field)) { 
                    if ($size == 1) {
                        # if PK is non-composite we can to add PRIMARY KEY clause
                        debug(3, "field $field is a primary key");
                        $pk = ' PRIMARY KEY' . $position;
                        $weight = 1;
                        $header_text = 'add_pk';
                        # Flag we add PK's column(s)
                        $self->{added_pk} = 1;
                        $self->{added_pk_col} = $field;
                    } else {
                        # This way, we can to add PRIMARY KEY __operator__ when last part of PK was obtained
                        debug(3, "field $field is a part of composite primary key");
                        if ($field eq $f_last) {
                            debug(3, "field '$field' is a last part of composite primary key");
                            my $p = $table2->primary_key();
                            $pk = $position . ", ADD PRIMARY KEY $p";
                            $weight = 1;
                            $header_text = 'add_pk';
                            # Flag we add PK's column(s)
                            $self->{added_pk} = 1;
                            $self->{added_pk_col} = $field;
                        }
                    }
                    $alters->{$field} = $self->_add_routine_alters($field, $field_links, $table2);
                }
                
                my $fks_for_added = $table2->get_fk_by_col($field);
                if ($fks_for_added) {
                    for my $fk_for_added (keys %$fks_for_added) {
                        # save foreign keys names in hash to check it after
                        $self->{added_for_fk}{$fk_for_added} = $weight;
                    }
                }
                
                my $field_description = $fields2->{$field};
                if (!$self->{added_pk} && ($field_description =~ /AUTO_INCREMENT/is)) {
                    debug(3, "field $field is auto increment, so it will be added without auto_increment clause and then changed when index will be added");
                    $self->{added_index}{field} = $field;
                    $self->{added_index}{is_new} = 1;
                    $self->{added_index}{desc} = $field_description;
                    $field_description =~ s/AUTO_INCREMENT//is;
                }
                my $change = '';
                $change =  $self->add_header($table2, $header_text) unless !$self->{opts}{'list-tables'};
                $change .= "ALTER TABLE $name1 ADD COLUMN $field $field_description$pk;\n";
                $self->{added_cols}{$field} = 1;
                if ($prev_field && $prev_field_links && $self->{timestamps}{$prev_field} && !$self->{timestamps}{$field}) {
                    # if last column is not timestamp column itself, and it was added after timestamp column, 
                    # we need to create "AFTER" because timestamp added with weight = 1
                    my $ts_alters = $self->_add_routine_alters($prev_field, $prev_field_links, $table2);
                    push @changes, [$ts_alters, {'k' => 1}];
                } 
                if (!$alters->{$field}) {
                    # flag we already have ALTER for field
                    $alters->{$field} = 1;
                } else {
                    $change .= $alters->{$field};
                }

                push @changes, [$change, {'k' => $weight}];
            }
        }
    }

    return @changes;
}

sub _add_routine_alters {
    my ($self, $current_field, $field_links, $table) = @_;
    my $res = '';
    my $fields = $table->fields;
    my $name = $table->name;
    while ($field_links->{'next_field'}) {
        my $next_field = $field_links->{'next_field'};
        if ($self->{added_cols}{$next_field}) {
            $res .= "ALTER TABLE $name CHANGE COLUMN $next_field $next_field $fields->{$next_field} AFTER $current_field;\n";   
        }
        $field_links = $table->fields_links($next_field);
        $current_field = $next_field;
    }
    return $res;
}

sub _add_index_wa_routines {
    my ($self, $table, $index_name, $stmt, $stmt_type) = @_;
    my $name = $self->{index_wa}{'name'};
    $self->{index_wa}{'used'} = 1;
    # remove quotes to use it in SELECT within stored procedure
    $table =~ s/`//sg;
    $index_name =~ s/`//sg;
    # quote statement string like addslashes() function in PHP
    $stmt =~ s/\\/\\\\/g;
    $stmt =~ s/'/\\'/g;
    $stmt =~ s/"/\\"/g;
    $stmt =~ s/\\0/\\\\0/g;
    return "CALL `$name` ('$table', '$index_name', '$stmt', '$stmt_type');"
}

sub _diff_indices {
    my ($self, $table1, $table2) = @_;
    my $name1 = $table1->name();

    my $indices1 = $table1->indices();
    my $opts1 = $table1->indices_opts();
    my $indices2 = $table2->indices();
    my $opts2 = $table2->indices_opts();

    return () unless $indices1 || $indices2;

    my @changes;
    my $index_wa_stmt;
    my $weight = 3; # index must be added/changed after column add/change and dropped before column drop

    if($indices1) {
        my $indexes_for_fks = {};
        for my $index (keys %$indices1) {
            # re-initialize weight
            $weight = 3; 
            my $ind1_opts = '';
            my $ind2_opts = '';
            if ($opts1 && $opts1->{$index}) {
                $ind1_opts = $opts1->{$index};
            }
            if ($opts2 && $opts2->{$index}) {
                $ind2_opts = $opts2->{$index};
            }
            debug(2,"$name1 had index '$index' with opts: $ind1_opts");
            my $old_type = $table1->is_unique($index) ? 'UNIQUE' : 
                           $table1->is_fulltext($index) ? 'FULLTEXT INDEX' : 'INDEX';
                           
            # if index has same name as FK in _first_ table, and there isn't FK in _second_ table,
            # so we will create DROP FK statement after and in deleting or changing index conditions
            # we will just "cover" index part columns with temporary indexes;
            # if index has same name as FK in _first_ table, and there _is_ FK in _second_ table,
            # so we will create DROP FK and then ADD FK statements after. 
            # So we need to check all parts of index are exists in this FK - in this case, we do not need to drop index
            # _before_ FK will be created; in other case, we must to do:
            # 1. ADD INDEX rc_temp_....  - to "cover" missing index part with temporary index
            # 2. DROP INDEX $index - to drop index before FK will be changed (it will automatically create index with this name again)
            # 3. Wait untill FK changing statements will be added to output 
            # 4. Do the rest of normal work (DROP $index again or change it)
            # for steps 1-2
            my $fks1 = $table1->foreign_key();
            my $fks2 = $table2->foreign_key();
            my $is_fk = 0;
            # for step 1
            my $rc_index_name = '';
            my $fk_col = '';
            # for step 2
            my $need_drop = 0;
            if ($table2->isa_fk($index)) {
                $fks1 = $fks1->{$index} || '';
                $fks2 = $fks2->{$index} || '';
                debug(3, "index '$index' has same name as foreign key constraint");
                debug(3, "FK in table1 is $fks1, FK in table2 is $fks2");
                if (!($fks1 eq $fks2)) {
                    debug(3, "index '$index' will be recreated");
                    $is_fk = 1;  
                } 
            }

            if ($indices2 && $indices2->{$index}) {
                if( ($indices1->{$index} ne $indices2->{$index}) or
                    ($table1->is_unique($index) xor $table2->is_unique($index)) or
                    ($table1->is_fulltext($index) xor $table2->is_fulltext($index))  or
                    ($ind1_opts ne $ind2_opts)
                  )
                {
                    debug(3,"index '$index' changed");
                    my $new_type = $table2->is_unique($index) ? 'UNIQUE' : 
                                   $table2->is_fulltext($index) ? 'FULLTEXT INDEX' : 'INDEX';
                        
                    my $auto = _check_for_auto_col($table2, $indices1->{$index}, 0) || '';
                    # try to check any of index part is AUTO_INCREMENT
                    my $auto_increment_check = _check_for_auto_col($table1, $indices1->{$index}, 0) || '';
                    if (!$auto) {
                         $auto = $auto_increment_check;
                    }
                    $auto_increment_check = $auto  ? 1 : 0;
                    my $changes = '';
                    $changes = $self->add_header($table2, "change_index") unless !$self->{opts}{'list-tables'};
                    $changes .= $auto ? $self->_index_auto_col($table1, $indices1->{$index}, $self->{opts}{'no-old-defs'}) : '';
                    if ($auto) {
                        my $auto_index_name = "mysqldiff_".md5_hex($name1."_".$auto);
                        debug(3, "Auto column $auto indexed with index called $auto_index_name");
                        if (!$self->{temporary_indexes}{$auto_index_name}) {
                            $self->{temporary_indexes}{$auto_index_name} = $auto;
                        }
                    }
                    my $is_timestamp = 0;
                    my $index_dropped_by_all_parts = 0;
                    my $index_part;
                    my $index_parts = $table1->indices_parts($index);
                    # check index parts is FK in second or first table, or it is timestamp column in second table
                    if ($index_parts) {
                        for $index_part (keys %$index_parts) {
                            my $fks = $table2->get_fk_by_col($index_part) || $table1->get_fk_by_col($index_part);
                            my $field_index_part = $table2->field($index_part);
                            if ($fks && $field_index_part) {
                                # now we can to check, if FK was deleted, etc. Instead of this, we can just to try create temp index 
                                my $temp_index_name = "temp_".md5_hex($index_part);
                                if (!$self->{temporary_indexes}{$temp_index_name}) {
                                    debug(3, "Added temporary index $temp_index_name for INDEX's field $index_part because there is FKs for this field");
                                    $self->{temporary_indexes}{$temp_index_name} = $index_part;
                                    $changes .= $self->_add_index_wa_routines(
                                            $name1, 
                                            $temp_index_name, 
                                            "ALTER TABLE $name1 ADD INDEX $temp_index_name ($index_part);", 
                                            'create'
                                    ) . "\n";
                                }
                            }
                            if ($field_index_part && ($field_index_part =~ /(CURRENT_TIMESTAMP(?:\(\))?|NOW\(\)|LOCALTIME(?:\(\))?|LOCALTIMESTAMP(?:\(\))?)/)) {
                                $weight = 1;
                                $is_timestamp = 1;
                            }
                        }
                    }
                    # check index part of this index is second table is its timestamp column
                    $index_parts = $table2->indices_parts($index);
                    my $added_pk_index_weight = 0;
                    if ($index_parts) {
                        for $index_part (keys %$index_parts) {
                            if ($is_fk) {
                                $fk_col = $table2->get_fk_by_col($index_part);
                                # do the step 1
                                if (!$fk_col || !($fk_col->{$index}) || !($fk_col->{$index} eq $fks1)) {
                                    $need_drop = 1;
                                    $rc_index_name = "rc_temp_".md5_hex($index_part)."_change";
                                    $self->{temporary_indexes}{$rc_index_name} = $index_part;
                                    debug(3, "Added temporary index $rc_index_name for INDEX's field $index_part because there is FK for this field in SECOND table and index $index has same name as FK");
                                    if ($self->{added_pk_col} eq $index_part) {
                                        $added_pk_index_weight = 1;
                                    } else {
                                        $added_pk_index_weight = $self->{added_for_fk}{$index} ? 5 : 6;
                                    }
                                    if ($self->{opts}{'list-tables'}) {
                                        push @changes, [$self->add_header($table2, "change_index"), {'k' => $added_pk_index_weight}];    
                                    }
                                    push @changes, [
                                        $self->_add_index_wa_routines($name1, $rc_index_name, "ALTER TABLE $name1 ADD INDEX $rc_index_name ($index_part);", 'create') . "\n", 
                                        {'k' => $added_pk_index_weight}
                                    ]; 
                                }
                            }
                            if ($table2->field($index_part) =~ /(CURRENT_TIMESTAMP(?:\(\))?|NOW\(\)|LOCALTIME(?:\(\))?|LOCALTIMESTAMP(?:\(\))?)/) {
                                $weight = 1;
                                $is_timestamp = 1;
                            }
                        }
                    }
                    # do the step 2
                    if ($need_drop) {
                        debug(3, "drop index $index to change it later FK changing");
                        $index_wa_stmt = '';
                        $index_wa_stmt = $self->add_header($table1, "drop_wa_index") unless !$self->{opts}{'list-tables'};
                        $index_wa_stmt .= $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 DROP INDEX $index;", 'drop');
                        push @changes, [$index_wa_stmt . "\n", {'k' => $self->{added_for_fk}{$index} ? 5 : 6}]; 
                    }                    
                    if ($is_timestamp) {
                        $index_parts = $table1->indices_parts($index);
                        if ($index_parts) {
                            my $iter = 0;
                            $index_dropped_by_all_parts = 1;
                            # if empty parts;
                            for $index_part (keys %$index_parts) {
                                $iter = 1;
                                debug(3, "check column $index_part is dropped");
                                # if in second table current column was dropped, check if all parts of index was dropped
                                $index_dropped_by_all_parts = $index_dropped_by_all_parts && $self->{dropped_columns}{$index_part};
                            }
                            if (!$iter) {
                                $index_dropped_by_all_parts = 0;
                            }
                        }
                    }
                    if ($index_dropped_by_all_parts) {
                        debug(3, "All parts of index $index was dropped, so timestamp column not needed in drop index");
                    }
                    else {
                        $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 DROP INDEX $index;", 'drop');
                        $changes .= $index_wa_stmt;
                        $changes .= " # was $old_type ($indices1->{$index})$ind1_opts"
                            unless $self->{opts}{'no-old-defs'};
                    }
                    $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 ADD $new_type $index ($indices2->{$index})$ind2_opts;", 'create');
                    $changes .= "\n" . $index_wa_stmt . "\n";
                    if (keys %{$self->{added_index}} && $auto_increment_check) {
                        # alter column after 
                        if ($self->{added_index}{is_new}) {
                            my $desc = $self->{added_index}{desc};
                            my $f = $self->{added_index}{field};
                            $changes .= "ALTER TABLE $name1 CHANGE COLUMN $f $f $desc;\n";
                        }
                        else {
                            $weight = 6; # in this case index must be added before column change
                        }
                        # reset added index description
                        $self->{added_index} = {};
                    }
                    push @changes, [$changes, {'k' => $added_pk_index_weight ? $added_pk_index_weight : $weight}]; 
                }
            } else {
                my $auto = _check_for_auto_col($table2, $indices1->{$index}, 0) || '';
                # try to check any of index part is AUTO_INCREMENT
                my $auto_increment_check = _check_for_auto_col($table1, $indices1->{$index}, 0) || '';
                if (!$auto) {
                    $auto = $auto_increment_check;
                }
                $auto_increment_check = $auto ? 1 : 0;
                my $changes = '';
                $changes = $self->add_header($table1, "drop_index") unless !$self->{opts}{'list-tables'};
                $changes .= $auto ? $self->_index_auto_col($table1, $indices1->{$index}, $self->{opts}{'no-old-defs'}) : '';
                if ($auto) {
                    my $auto_index_name = "mysqldiff_".md5_hex($name1."_".$auto);
                    debug(3, "Auto column $auto indexed with index called $auto_index_name");
                    if ($auto_increment_check && $self->{dropped_columns}{$auto}) {
                        debug(3, "Index $auto_index_name was not added to temporary indexes, because of column will be dropped");
                    }
                    else {
                        if (!$self->{temporary_indexes}{$auto_index_name}) {
                            debug(3, "Index $auto_index_name was added to temporary indexes, because of column will not be dropped and is auto increment") if $auto_increment_check;
                            $self->{temporary_indexes}{$auto_index_name} = $auto;
                        }
                    }
                }
                my $index_parts = $table1->indices_parts($index);
                my $is_empty_change = 0;
                if ($index_parts) {
                    for my $index_part (keys %$index_parts) {
                        if ($is_fk) {
                            $fk_col = $table2->get_fk_by_col($index_part);
                            # do the step 1
                            if (!$fk_col || !($fk_col->{$index}) || !($fk_col->{$index} eq $fks1)) {
                                $need_drop = 1;
                                $rc_index_name = "rc_temp_".md5_hex($index_part)."_drop";
                                $self->{temporary_indexes}{$rc_index_name} = $index_part;
                                debug(3, "Added temporary index $rc_index_name for INDEX's field $index_part in drop index condition because there is FK for this field in SECOND table and index $index has same name as FK");
                                push @changes, [
                                    $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 ADD INDEX $rc_index_name ($index_part);", 'create') . "\n", 
                                    {'k' => $self->{added_for_fk}{$index} ? 5 : 6}
                                ]; 
                            }
                        }
                        my $fks = $table2->get_fk_by_col($index_part) || $table1->get_fk_by_col($index_part);
                        if ($fks) {
                            my $temp_index_name = "temp_".md5_hex($index_part);
                            if (!$self->{temporary_indexes}{$temp_index_name}) {
                                debug(3, "Added temporary index $temp_index_name for INDEX's field $index_part because there is FKs for this field");
                                $self->{temporary_indexes}{$temp_index_name} = $index_part;
                                $changes .= $self->_add_index_wa_routines($name1, $temp_index_name, "ALTER TABLE $name1 ADD INDEX $temp_index_name ($index_part);", 'create') . "\n";
                            }
                        }
                        if (defined($self->{changed_to_empty_char_col}{$index_part})) {
                            $weight = $self->{changed_to_empty_char_col}{$index_part} + 1;
                        }
                    }
                }
                # do the step 2
                if ($need_drop) {
                    debug(3, "drop index $index to drop it later FK changing");
                    $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 DROP INDEX $index;", 'drop');
                    push @changes, [$index_wa_stmt . "\n", {'k' => $self->{added_for_fk}{$index} ? 5 : 6}]; 
                }  
                $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 DROP INDEX $index;", 'drop');
                $changes .= $index_wa_stmt;
                $changes .= " # was $old_type ($indices1->{$index})$ind1_opts" 
                    unless $self->{opts}{'no-old-defs'};
                $changes .= "\n";
                if (keys %{$self->{added_index}} && $auto_increment_check) {
                    # alter column after 
                    if ($self->{added_index}{is_new}) {
                        my $desc = $self->{added_index}{desc};
                        my $f = $self->{added_index}{field};
                        $changes .= "ALTER TABLE $name1 CHANGE COLUMN $f $f $desc;\n";
                    }
                    else {
                        $weight = 6; # in this case index must be added before column change
                    }
                }
                push @changes, [$changes, {'k' => $weight}];
            }
        }
    }

    if($indices2) {
        for my $index (keys %$indices2) {
            next    if($indices1 && $indices1->{$index});
            debug(2,"index '$index' added");
            my $need_recreate = 0;
            my $is_fk = 0;
            if ($table2->isa_fk($index)) {
                debug(3, "index '$index' has same name as foreign key constraint in second table");
                if (!$table1->isa_fk($index)) {
                    debug(3, "index '$index` is not FK in first table, so it will be automatically added after FK creation");
                    $is_fk = 1;
                }
                else {
                    # in this case we need to compare FKs in both tables
                    my $cmp_fks1 = $table1->foreign_key();
                    my $cmp_fks2 = $table2->foreign_key();
                    my $cmp_fk1 = $cmp_fks1->{$index} || '';
                    my $cmp_fk2 = $cmp_fks2->{$index} || '';
                    # if fk1 is not equal to fk2, there will be generated change FK statements
                    # in this case, index will be automatically added after FK drop and create
                    if ($cmp_fk1 eq $cmp_fk2) {
                        debug(3, "FKs are identically in both tables, so we need to create index '$index'");
                    }
                    else {
                        $is_fk = 1;
                        debug(3, "FKs are not identically in tables, so index '$index' will be automatically created after FK recreation");
                    }
                }
            }
            my $new_type = $table2->is_unique($index) ? 'UNIQUE' : 'INDEX';
            my $opts = '';
            if ($opts2->{$index}) {
                $opts = $opts2->{$index};
            }
            my $parts = $table2->indices_parts($index);
            my $changes = '';
            # indexes for PK and timestamp columns 
            for my $ip (keys %$parts) {
                if ($is_fk) {
                    my $col_fk = $table2->get_fk_by_col($ip);
                    # if one of parts of index was not in fk, we will need to change index (drop it and then to create again)
                    # in other way, index will NOT be created, if it is FK and all parts of it equal to FK parts (because in MySQL constraint automatically creates index)
                    if (!$col_fk || !($col_fk->{$index})) {
                        my $temp_index_name = "rc_temp_".md5_hex($ip)."_add";
                        debug(3, "need recreate index $index, add temporary index $temp_index_name for $ip");
                        $self->{temporary_indexes}{$temp_index_name} = $ip;
                        $changes .= $self->_add_index_wa_routines($name1, $temp_index_name, "ALTER TABLE $name1 ADD INDEX $temp_index_name ($ip);", 'create') . "\n";
                        $need_recreate = 1;
                    }
                }
                if ($table2->isa_primary($ip)) {
                    $weight = 1;
                    last;
                }
                if ($table2->field($ip) =~ /(CURRENT_TIMESTAMP(?:\(\))?|NOW\(\)|LOCALTIME(?:\(\))?|LOCALTIMESTAMP(?:\(\))?)/) {
                    $weight = 1;
                    last;
                }
            }
            
            my $tmp_changes = $changes;
            $changes = '';
            $changes = $self->add_header($table2, "add_index") unless !$self->{opts}{'list-tables'};
            $changes .= $tmp_changes;
            if ($need_recreate) {
                debug(3, "drop index $index to recreate it");
                $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 DROP INDEX $index;", 'drop');
                $changes .= $index_wa_stmt . "\n";
            }
            if (!$is_fk || $need_recreate) {
                $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 ADD $new_type $index ($indices2->{$index})$opts;", 'create');
                $changes .= $index_wa_stmt . "\n";
                my $auto = _check_for_auto_col($table2, $indices2->{$index}, 0) || '';
                if (keys %{$self->{added_index}} && $auto) {
                    # alter column after 
                    if ($self->{added_index}{is_new}) {
                        my $desc = $self->{added_index}{desc};
                        my $f = $self->{added_index}{field};
                        $changes .= "ALTER TABLE $name1 CHANGE COLUMN $f $f $desc;\n";
                    }
                    else {
                        $weight = 6; # in this case index must be added before column change
                    }
                }
                push @changes, [$changes, {'k' => $weight}];
            }
            if ($is_fk && !$need_recreate) {
                # if there is already key for FK, or it is not dropped yet (will be dropped after), we need to try create index 
                $index_wa_stmt = $self->_add_index_wa_routines($name1, $index, "ALTER TABLE $name1 ADD $new_type $index ($indices2->{$index})$opts;", 'create');
                $changes .= $index_wa_stmt . "\n";
                push @changes, [$changes, {'k' => $weight}];
            }
        }
    }

    return @changes;
}

sub _diff_primary_key {
    my ($self, $table1, $table2) = @_;

    my $name1 = $table1->name();

    my $primary1 = $table1->primary_key();
    my $primary2 = $table2->primary_key();

    return () unless $primary1 || $primary2;

    my @changes;

    if (! $primary1 && $primary2) {
        if ($self->{added_pk}) {
                return ();
        }
        debug(2,"primary key '$primary2' added");
        my $changes = '';
        $changes .= $self->add_header($table2, "add_pk") unless !$self->{opts}{'list-tables'};
        $changes .= "ALTER TABLE $name1 ADD PRIMARY KEY $primary2;\n";
        return ["$changes\n", {'k' => 3}]; 
    }
  
    my $changes = '';
    my $action_type = '';
    my $k = 3;
    if ( ($primary1 && !$primary2) || ($primary1 ne $primary2) ) {
        debug(2, "primary key difference detected");
        my $auto = _check_for_auto_col($table2, $primary1) || '';
        $changes .= $auto ? $self->_index_auto_col($table2, $auto, $self->{opts}{'no-old-defs'}) : '';
        if ($auto) {
            debug(3, "Auto column $auto indexed");
            my $auto_index_name = "mysqldiff_".md5_hex($name1."_".$auto);
            if (!$self->{temporary_indexes}{$auto_index_name}) {
                $self->{temporary_indexes}{$auto_index_name} = $auto;
            }
        }
        my $pks = $table1->primary_parts();
        my $pk_ops = 1; 
        my $fks;
        # for every part in primary key (if non-composite, there will be only one part)
        for my $pk (keys %$pks) {
            if ($self->{dropped_columns}{$pk}) {
                debug(3, "PK's $pk column was dropped");
            }
            # store result, all of parts was dropped or not
            $pk_ops = $pk_ops && $self->{dropped_columns}{$pk};
            # for every part we also get foreign keys and add temporary indexes
            $fks = $table2->get_fk_by_col($pk) || $table1->get_fk_by_col($pk);
            if ($fks) {
                my $temp_index_name = "temp_".md5_hex($pk);
                if (!$self->{temporary_indexes}{$temp_index_name}) {
                    debug(3, "Added temporary index $temp_index_name for PK's field $pk because there is FKs for this field");
                    $self->{temporary_indexes}{$temp_index_name} = $pk;
                    $changes .= $self->_add_index_wa_routines($name1, $temp_index_name, "ALTER TABLE $name1 ADD INDEX $temp_index_name ($pk);", 'create') . "\n";
                }
            }
        }
        # If PK's column(s) ALL was dropped, we mustn't drop itself; for auto columns we already create indexes
        if (!$pk_ops) {
            debug(2, "Old PK $primary1 was dropped");
            $changes .= "ALTER TABLE $name1 DROP PRIMARY KEY";
            if ($self->{changed_pk_auto_col}) {
                $changes .= ', ' . $self->{changed_pk_auto_col}; 
            } else {
                $changes .= ';';
            }
            $changes .= " # was $primary1" unless $self->{opts}{'no-old-defs'};
            $changes .= "\n";
        }
        if ($primary1 && !$primary2) {
            debug(2,"primary key '$primary1' dropped");
            $k = 4; # DROP PK FIRST
            $action_type = 'drop_pk';
        } else {
            debug(2,"primary key changed");
            $action_type = 'change_pk';
            # If PK's column was added, we mustn't add itself
            if ($self->{added_pk}) {
                debug(3, "PK was already added");
                $k = 8; # In this case we must to do all work before column will be added
            } else {
                debug(3, "PK $primary2 was added");
                $changes .= "ALTER TABLE $name1 ADD PRIMARY KEY $primary2;\n"; 
                if ($pk_ops) {
                    $k = 0; # In this case we must to do all work in the final
                }
            }   
        }               
    }

    if ($changes) {
        $changes = $self->add_header($table1, $action_type) . $changes unless !$self->{opts}{'list-tables'};
        push @changes, [$changes, {'k' => $k}]; 
    }
    return @changes;
}

sub _diff_foreign_key {
    my ($self, $table1, $table2) = @_;

    my $name1 = $table1->name();

    my $fks1 = $table1->foreign_key();
    my $fks2 = $table2->foreign_key();

    return () unless $fks1 || $fks2;

    my @changes;
  
    if($fks1) {
        for my $fk (keys %$fks1) {
            debug(2,"$name1 has fk '$fk'");

            if ($fks2 && $fks2->{$fk}) {
                if($fks1->{$fk} ne $fks2->{$fk})  
                {
                    debug(3,"foreign key '$fk' changed");
                    my $changes = '';
                    $changes = $self->add_header($table1, 'change_fk', 1) unless !$self->{opts}{'list-tables'};
                    my $dropped_columns = $self->{dropped_columns};
                    my $dropped_column_fks;
                    my $changed_columns = $self->{changed_for_fk}{$fk};
                    $changes .= "ALTER TABLE $name1 DROP FOREIGN KEY $fk;";
                    $changes .= " # was CONSTRAINT $fk FOREIGN KEY $fks1->{$fk}"
                        unless $self->{opts}{'no-old-defs'};
                    for my $dk (keys %$dropped_columns) {
                        $dropped_column_fks = $table1->get_fk_by_col($dk);
                        for my $dropped_column_fk (keys %$dropped_column_fks) {
                            if ($dropped_column_fk eq $fk) {
                                # column which this fk references was dropped, so now it's referenced to another column (may be new column, we dont need to know it)
                                # in this case, we must to drop fk before column drop
                                push @changes, [$changes . "\n", {'k' => 6}]; 
                                $changes = '';
                            }
                        }
                    }
                    # CHANGE FK after column for it may be changed
                    my $weight = 5;
                    my $min_weight = $weight;
                    if ($changed_columns) {
                        $changes .= "\n";
                        for my $changed_col (keys %$changed_columns) {
                            my $changed_data    = $changed_columns->{$changed_col};
                            my $changed_weight  = $changed_data->{'weight'};
                            my $changed_stmt    = $changed_data->{'stmt'};
                            if ($changed_weight > $weight) {
                                $weight = $changed_weight;
                            }
                            if ($changed_weight < $min_weight) {
                                $min_weight = $changed_weight;
                            }
                            push @changes, [$changed_stmt, {'k' => $changed_weight}];
                        }
                        push @changes, [$changes, {'k' => $weight}];
                        $changes = '';
                    }
                    $weight = $min_weight;
                    if (!$changes) {
                        $changes = $self->add_header($table1, 'change_fk', 1) unless !$self->{opts}{'list-tables'};
                    } else {
                        $changes .= "\n";
                    }
                    $changes .= "ALTER TABLE $name1 ADD CONSTRAINT $fk FOREIGN KEY $fks2->{$fk};\n";
                    if ($self->{added_for_fk}{$fk}) {
                        # if fk was changed and it reference by new column, change it after column adding
                        $weight = $self->{added_for_fk}{$fk};
                    }
                    push @changes, [$changes, {'k' => $weight}]; 
                }
            } else {
                debug(3,"foreign key '$fk' removed");
                my $changes = '';
                $changes = $self->add_header($table1, 'drop_fk') unless !$self->{opts}{'list-tables'};
                $changes .= "ALTER TABLE $name1 DROP FOREIGN KEY $fk;";
                $changes .= " # was CONSTRAINT $fk FOREIGN KEY $fks1->{$fk}"
                        unless $self->{opts}{'no-old-defs'};
                $changes .= "\n";
                push @changes, [$changes, {'k' => 6}]; # DROP FK FIRST
            }
        }
    }

    if($fks2) {
        for my $fk (keys %$fks2) {
            next    if($fks1 && $fks1->{$fk});
            debug(3, "foreign key '$fk' added");
            my $change = '';
            $change = $self->add_header($table2, 'add_fk', 1) unless !$self->{opts}{'list-tables'};
            $change .= "ALTER TABLE $name1 ADD CONSTRAINT $fk FOREIGN KEY $fks2->{$fk};\n";
            push @changes, [$change, {'k' => 1}]; # add FK after all
        }
    }

    return @changes;
}

# If we're about to drop a composite (multi-column) index, we need to
# check whether any of the columns in the composite index are
# auto_increment; if so, we have to add an index for that
# auto_increment column *before* dropping the composite index, since
# auto_increment columns must always be indexed.
sub _check_for_auto_col {       
    my ($table, $fields, $primary) = @_;

    $fields =~ s/^\s*\((.*)\)\s*$/$1/g; # strip brackets if any
    my @fields = split /\s*,\s*/, $fields;
    
    for my $field (@fields) {
        my $not_is_field = (!$table->field($field));
        debug(3, "field '$field' not exists in table in second database") if $not_is_field;
        next if $not_is_field;
        my $not_AI = ($table->field($field) !~ /auto_increment/i);
        debug(3, "field '$field' is not AUTO_INCREMENT in table in second database (" . $table->field($field)  . ")") if $not_AI;
        next if $not_AI;
        #next if($table->isa_index($field));
        my $pk = ($primary && $table->isa_primary($field));
        debug(3, "field '$field' is PK in table in second database") if $pk;
        next if $pk;

        return $field;
    }

    return;
}

sub _index_auto_col {
    my ($self, $table, $field, $comment) = @_;
    my $name = $table->name;
    my $auto_index_name = "mysqldiff_".md5_hex($name."_".$field);
    if (!($field =~ /\(.*?\)/)) {
        $field = '(' . $field . ')';
    }

    my $changes = "ALTER TABLE $name ADD INDEX $auto_index_name $field;";
    $changes .= " # auto columns must always be indexed"
                        unless $comment;
    return $self->_add_index_wa_routines($name, $auto_index_name, $changes, 'create') . "\n";
}

sub _diff_options {
    my ($self, $table1, $table2) = @_;
    my $name = $table1->name();
    debug(2, "looking at options of $name");
    my @changes;
    my $change = '';
    if ($self->{temporary_indexes}) {
        for my $temporary_index (keys %{$self->{temporary_indexes}}) {
            my $column = $self->{temporary_indexes}{$temporary_index};
            if ($self->{dropped_columns}{$column}) {
                debug(3, "Column $column was already dropped, so we must not drop temporary index");
            } else {
                debug(3, "Dropped temporary index $temporary_index");
                my $tmp_change = '';
                $tmp_change .= $self->add_header($table1, 'drop_temporary_index') unless !$self->{opts}{'list-tables'};
                $tmp_change .= $self->_add_index_wa_routines($name, $temporary_index, "ALTER TABLE $name DROP INDEX $temporary_index;", 'drop') . "\n";
                if (defined($self->{changed_to_empty_char_col}{$column})) {
                    push @changes, [$tmp_change, {'k' => $self->{changed_to_empty_char_col}{$column} + 1}];
                } else {
                    $change .= $tmp_change;
                }
            }
        }
    }

    my $options1 = $table1->options();
    my $options2 = $table2->options();

    if (!$options1) {
        $options1 = '';
    }
    if (!$options2) {
        $options2 = '';
    }

    if ($self->{opts}{tolerant}) {
      for ($options1, $options2) {
        s/ AUTO_INCREMENT=\d+//gi;
        s/ COLLATE=[\w_]+//gi;
      }
    }

    my $opt_header = 'change_options';
    my $k = 8;
    if ($options1 ne $options2) {
        debug(2, "$name options was changed");
        if (!($options2 =~ /COMMENT='.*?'/i)) {
            $options2 = "COMMENT='' " . $options2;
        }
        my $before_part = $options2;
        my $opt_change = '';
        if ($options2 =~ /(.*)PARTITION BY(.*)/is) {
            $opt_header = 'change_partitions';
            $before_part = $1;
            my $part2 = $2;
            if ($options1 =~ /PARTITION BY(.*)/is) {
                my $part1 = $1;
                if ($part2 ne $part1) {
                    debug(4, "PARTITION of table '$name' in first database is $part1, but in second is $part2");
                    $opt_change = $self->add_header($table1, 'drop_partitioning') unless !$self->{opts}{'list-tables'};
                    $opt_change .= "ALTER TABLE $name REMOVE PARTITIONING;\n";
                    push @changes, [$opt_change, {'k' => 8}]; 
                    $k = 0;
                    # alternatively we must parse partition definition and get all fields (which may be in functions, for example)
                } else {
                    debug(4, "PARTITION of table '$name' in all databases are equal\nFirst: $part1\nSecond: $part2");
                }
            } else {
                debug(3, "No partitions in table in first database, so we just add them");
            }
            # last, we must to change options (if there was partitions, options will be have substring of options without partitions definition)
            $change .= $self->add_header($table1, $opt_header) unless !$self->{opts}{'list-tables'};
            $change .= "ALTER TABLE $name $options2;";
            $change .= " # was " . ($options1 || 'blank') unless $self->{opts}{'no-old-defs'};
            $change .= "\n";
        } else {
            if ($options1 =~ /PARTITION BY/) {
                # drop partitions
                debug(3, "drop partitions from table '$name'");
                $opt_change = $self->add_header($table1, 'drop_partitioning') unless !$self->{opts}{'list-tables'};
                $opt_change .= "ALTER TABLE $name REMOVE PARTITIONING;\n";
                push @changes, [$opt_change, {'k' => 8}]; 
            }
        }
        # change table options without partitions first
        $opt_change = $self->add_header($table1, 'change_options') unless !$self->{opts}{'list-tables'};
        $opt_change .= "ALTER TABLE $name $before_part;\n";
        push @changes, [$opt_change, {'k' => 8}]; 
    }

    if ($change) {
        push @changes, [$change, {'k' => 0}]; # the lastest
    }

    return @changes;
}

sub _load_database {
    my ($self, $arg, $authnum) = @_;

    debug(1, "Load database: parsing arg $authnum: '$arg'\n");

    my %auth;
    for my $auth (qw/dbh host port user password socket/) {
        $auth{$auth} = $self->{opts}{"$auth$authnum"} || $self->{opts}{$auth};
        delete $auth{$auth} unless $auth{$auth};
    }

    if ($arg =~ /^db:(.*)/) {
        return MySQL::Diff::Database->new(db => $1, auth => \%auth);
    }

    if ($self->{opts}{"dbh"}              ||
        $self->{opts}{"host$authnum"}     ||
        $self->{opts}{"port$authnum"}     ||
        $self->{opts}{"user$authnum"}     ||
        $self->{opts}{"password$authnum"} ||
        $self->{opts}{"socket$authnum"}) {
        return MySQL::Diff::Database->new(db => $arg, auth => \%auth);
    }

    if (-f $arg) {
        return MySQL::Diff::Database->new(file => $arg, auth => \%auth);
    }

    my %dbs = MySQL::Diff::Database::available_dbs(%auth);
    debug(1, "  available databases: ", (join ', ', keys %dbs), "\n");

    if ($dbs{$arg}) {
        return MySQL::Diff::Database->new(db => $arg, auth => \%auth);
    }

    warn "'$arg' is not a valid file or database.\n";
    return;
}

sub _debug_level {
    my ($self,$level) = @_;
    debug_level($level);
}

sub add_header {
    my ($self, $table, $type, $add_referenced, $asis) = @_;
    my $name;
    if ($asis) {
        $name = $table;
    }
    else {
        $name = $table->name();
    }
    my $comment = "-- {\n-- \t\"name\" : \"$name\",\n";
    $comment .= "-- \t\"action_type\" : \"$type\"";
    if ($add_referenced) {
        my $additional_fk_tables = $table->fk_tables();
        if ($additional_fk_tables) {
            $comment .= ",\n-- \t\"referenced_tables\" : [\n";
            $comment .= "-- \t\t\"" . join "\",\n-- \t\t\"", keys %$additional_fk_tables; 
            $comment .= "\"\n-- \t]";
        }
    }
    $comment .= "\n-- }\n";
    return $comment;
}

1;

__END__

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2000-2011 Adam Spiers. All rights reserved. This
program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=head1 SEE ALSO

L<mysqldiff>, L<MySQL::Diff::Database>, L<MySQL::Diff::Table>, L<MySQL::Diff::Utils>

=head1 AUTHOR

Adam Spiers <mysqldiff@adamspiers.org>

=cut
