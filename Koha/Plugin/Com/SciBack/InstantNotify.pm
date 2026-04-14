package Koha::Plugin::Com::SciBack::InstantNotify;

# SciBack Instant Notify — Koha Plugin
# Envía notificaciones en tiempo real para transacciones de circulación
# (checkout, checkin, renewal) vía email y/o SMS, sin depender del cron.
#
# Copyright 2026 SciBack <soporte@sciback.pe>
# License: GPL-3.0-or-later

use Modern::Perl;
use utf8;
use base qw(Koha::Plugins::Base);

use Try::Tiny;
use C4::Context;
use Koha::Email;
use Koha::SMTP::Servers;
use Koha::DateUtils qw(dt_from_string output_pref);

our $VERSION = '1.1.0';

our $metadata = {
    name            => 'SciBack Instant Notify',
    author          => 'SciBack <soporte@sciback.pe>',
    description     => 'Notificaciones instantáneas de circulación vía email y SMS (checkout, devolución, renovación). Producto SciBack.',
    date_authored   => '2026-04-14',
    date_updated    => '2026-04-14',
    minimum_version => '22.11',
    maximum_version => undef,
    version         => $VERSION,
    namespace       => 'sciback_instant_notify',
};

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;
    return $class->SUPER::new($args);
}

# ─── Hook principal ────────────────────────────────────────────────────────────

sub after_circ_action {
    my ( $self, $params ) = @_;

    my $action   = $params->{action}          // return;
    my $checkout = $params->{payload}{checkout} // return;

    return unless $self->retrieve_data("enable_$action");

    my $patron = try { $checkout->patron } catch { return };
    return unless $patron;

    my $item = try { $checkout->item } catch { return };
    return unless $item;

    my $biblio = try { $item->biblio } catch { undef };

    my $data = {
        action   => $action,
        patron   => $patron,
        item     => $item,
        biblio   => $biblio,
        checkout => $checkout,
    };

    # Email — si tiene al menos una dirección registrada (email o emailpro)
    $self->_send_email($data) if $patron->email || $patron->emailpro;

    # SMS — si tiene número registrado
    $self->_send_sms($data) if $patron->smsalertnumber;

    return;
}

# ─── Envío de email ────────────────────────────────────────────────────────────

sub _send_email {
    my ( $self, $data ) = @_;

    my $action   = $data->{action};
    my $patron   = $data->{patron};
    my $item     = $data->{item};
    my $biblio   = $data->{biblio};
    my $checkout = $data->{checkout};

    # Recopilar todos los emails del patron (email + emailpro si existen)
    my @to_emails = grep { $_ && $_ =~ /\@/ }
                    ( $patron->email // '', $patron->emailpro // '' );
    my %seen;
    @to_emails = grep { !$seen{$_}++ } @to_emails;  # deduplicar
    return unless @to_emails;

    my $subject_tpl = $self->retrieve_data("subject_$action")
        // $self->_default_subject($action);
    my $body_tpl = $self->retrieve_data("body_$action")
        // $self->_default_body($action);

    my %vars = $self->_build_vars($data);

    my $subject = $subject_tpl;
    my $body    = $body_tpl;
    for my $var ( keys %vars ) {
        my $val = $vars{$var} // '';
        $subject =~ s/\Q$var\E/$val/g;
        $body    =~ s/\Q$var\E/$val/g;
    }

    my $from = $self->retrieve_data('from_address')
        // C4::Context->preference('KohaAdminEmailAddress')
        // '';

    return unless $from;

    utf8::decode($subject) unless utf8::is_utf8($subject);
    utf8::decode($body)    unless utf8::is_utf8($body);

    # Enviar a cada dirección registrada (email + emailpro)
    for my $to_email (@to_emails) {
        my $sent = 0;
        my $error_msg = '';

        try {
            local $SIG{ALRM} = sub { die "timeout\n" };
            alarm( $self->retrieve_data('smtp_timeout') // 8 );

            my $email = Koha::Email->create({
                to      => $to_email,
                from    => $from,
                subject => $subject,
                ( $self->_is_html($body)
                    ? ( html_body => $body )
                    : ( text_body => $body )
                ),
            });

            my $smtp = Koha::SMTP::Servers->get_default;
            $email->send_or_die({ transport => $smtp->transport });
            alarm(0);
            $sent = 1;
        }
        catch {
            alarm(0);
            $error_msg = "$_";
            warn "[SciBack::InstantNotify] Error SMTP para $to_email ($action): $error_msg";

            if ( $self->retrieve_data('fallback_to_queue') // 1 ) {
                try {
                    require C4::Letters;
                    C4::Letters::EnqueueLetter({
                        letter => {
                            title        => $subject,
                            content      => $body,
                            content_type => $self->_is_html($body) ? 'text/html' : 'text/plain',
                        },
                        borrowernumber         => $patron->borrowernumber,
                        message_transport_type => 'email',
                        to_address             => $to_email,
                        from_address           => $from,
                    });
                    $sent = 2;
                };
            }
        };

        $self->_log_notification({
            action         => $action,
            channel        => 'email',
            borrowernumber => $patron->borrowernumber,
            itemnumber     => $item->itemnumber,
            to_address     => $to_email,
            status         => $sent == 1 ? 'sent' : ( $sent == 2 ? 'queued_fallback' : 'failed' ),
            error_message  => $error_msg,
        });
    }

    return 1;
}

# ─── Envío de SMS ──────────────────────────────────────────────────────────────

sub _send_sms {
    my ( $self, $data ) = @_;

    my $action  = $data->{action};
    my $patron  = $data->{patron};
    my $item    = $data->{item};

    return unless $self->retrieve_data("enable_sms_$action") // 1;

    my $sms_number = $patron->smsalertnumber;
    return unless $sms_number;

    my $hub_url = $self->retrieve_data('sms_hub_url')    // '';
    my $hub_key = $self->retrieve_data('sms_hub_apikey') // '';
    return unless $hub_url && $hub_key;

    # Construir mensaje desde template
    my $tpl = $self->retrieve_data("sms_$action")
        // $self->_default_sms($action);

    my %vars = $self->_build_vars($data);
    my $message = $tpl;
    for my $var ( keys %vars ) {
        my $val = $vars{$var} // '';
        $message =~ s/\Q$var\E/$val/g;
    }

    # Truncar a 160 caracteres
    $message = substr($message, 0, 160) if length($message) > 160;

    my $sent = 0;
    my $error_msg = '';

    try {
        require HTTP::Tiny;
        require JSON;

        my $http = HTTP::Tiny->new(
            timeout => $self->retrieve_data('smtp_timeout') // 8,
        );

        my $resp = $http->request(
            'POST',
            "$hub_url/api/v1/sms/send",
            {
                headers => {
                    'Content-Type' => 'application/json',
                    'X-API-Key'    => $hub_key,
                },
                content => JSON::encode_json({ to => $sms_number, message => $message }),
            }
        );

        if ( $resp->{success} ) {
            $sent = 1;
        } else {
            $error_msg = "HTTP $resp->{status}: " . ( $resp->{content} // '' );
            warn "[SciBack::InstantNotify] Error SMS para $sms_number ($action): $error_msg";
        }
    }
    catch {
        $error_msg = "$_";
        warn "[SciBack::InstantNotify] Excepción SMS para $sms_number ($action): $error_msg";
    };

    $self->_log_notification({
        action         => $action,
        channel        => 'sms',
        borrowernumber => $patron->borrowernumber,
        itemnumber     => $item->itemnumber,
        to_address     => $sms_number,
        status         => $sent ? 'sent' : 'failed',
        error_message  => $error_msg,
    });

    return $sent;
}

# ─── Variables comunes para templates ─────────────────────────────────────────

sub _build_vars {
    my ( $self, $data ) = @_;

    my $action   = $data->{action};
    my $patron   = $data->{patron};
    my $item     = $data->{item};
    my $biblio   = $data->{biblio};
    my $checkout = $data->{checkout};

    my $title   = $biblio ? $biblio->title  : 'Material';
    my $author  = $biblio ? $biblio->author : '';
    my $barcode = $item->barcode           // '';
    my $callnum = $item->itemcallnumber    // '';
    my $nombre  = join( ' ', grep { $_ } $patron->firstname, $patron->surname );
    my $cardnum = $patron->cardnumber      // '';

    my $date_due_str = '';
    if ( $action ne 'checkin' ) {
        my $date_due = try { $checkout->date_due } catch { undef };
        if ($date_due) {
            try {
                my $dt = ref($date_due) && ref($date_due) ne 'SCALAR'
                    ? $date_due
                    : dt_from_string("$date_due");
                $date_due_str = output_pref({
                    dt         => $dt,
                    dateformat => 'metric',
                    timeformat => '24hr',
                    dateonly   => 0,
                });
            } catch {
                $date_due_str = "$date_due";
            };
        }
    }

    my $branch_name = '';
    try {
        require Koha::Libraries;
        my $branch_code = $checkout->branchcode // $item->holdingbranch // '';
        if ($branch_code) {
            my $library = Koha::Libraries->find($branch_code);
            $branch_name = $library->branchname if $library;
        }
    };

    return (
        '<<borrowers.firstname>>'  => $patron->firstname // '',
        '<<borrowers.surname>>'    => $patron->surname   // '',
        '<<borrowers.cardnumber>>' => $cardnum,
        '<<items.barcode>>'        => $barcode,
        '<<items.itemcallnumber>>' => $callnum,
        '<<biblio.title>>'         => $title,
        '<<biblio.author>>'        => $author,
        '<<checkout.date_due>>'    => $date_due_str,
        '<<branches.branchname>>'  => $branch_name,
        '<<nombre_completo>>'      => $nombre,
        '<<opac_url>>'             => C4::Context->preference('OPACBaseURL') // '',
        '<<library_name>>'         => C4::Context->preference('LibraryName') // 'Biblioteca',
    );
}

# ─── Log ──────────────────────────────────────────────────────────────────────

sub _log_notification {
    my ( $self, $args ) = @_;
    try {
        my $dbh = C4::Context->dbh;
        $dbh->do(
            'INSERT INTO plugin_sciback_notify_log
             (action, channel, borrowernumber, itemnumber, to_address, status, error_message, sent_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, NOW())',
            undef,
            $args->{action},
            $args->{channel}        // 'email',
            $args->{borrowernumber},
            $args->{itemnumber},
            $args->{to_address},
            $args->{status},
            $args->{error_message}  // '',
        );
    };
}

# ─── Configuración ────────────────────────────────────────────────────────────

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('save') ) {
        $self->store_data({
            enable_checkout      => scalar( $cgi->param('enable_checkout') )      ? 1 : 0,
            enable_checkin       => scalar( $cgi->param('enable_checkin') )        ? 1 : 0,
            enable_renewal       => scalar( $cgi->param('enable_renewal') )        ? 1 : 0,
            from_address         => scalar( $cgi->param('from_address') )          // '',
            fallback_to_queue    => scalar( $cgi->param('fallback_to_queue') )     ? 1 : 0,
            smtp_timeout         => int( scalar( $cgi->param('smtp_timeout') ) || 8 ),
            subject_checkout     => scalar( $cgi->param('subject_checkout') )     // '',
            subject_checkin      => scalar( $cgi->param('subject_checkin') )      // '',
            subject_renewal      => scalar( $cgi->param('subject_renewal') )      // '',
            body_checkout        => scalar( $cgi->param('body_checkout') )        // '',
            body_checkin         => scalar( $cgi->param('body_checkin') )         // '',
            body_renewal         => scalar( $cgi->param('body_renewal') )         // '',
            # SMS
            enable_sms_checkout  => scalar( $cgi->param('enable_sms_checkout') )  ? 1 : 0,
            enable_sms_checkin   => scalar( $cgi->param('enable_sms_checkin') )   ? 1 : 0,
            enable_sms_renewal   => scalar( $cgi->param('enable_sms_renewal') )   ? 1 : 0,
            sms_hub_url          => scalar( $cgi->param('sms_hub_url') )          // '',
            sms_hub_apikey       => scalar( $cgi->param('sms_hub_apikey') )       // '',
            sms_checkout         => scalar( $cgi->param('sms_checkout') )         // '',
            sms_checkin          => scalar( $cgi->param('sms_checkin') )          // '',
            sms_renewal          => scalar( $cgi->param('sms_renewal') )          // '',
        });
        print $cgi->redirect( -uri => $cgi->referer || '/cgi-bin/koha/plugins/plugins-home.pl' );
        return;
    }

    my $template = $self->get_template({ file => 'configure.tt' });

    my $recent_log = [];
    try {
        my $dbh = C4::Context->dbh;
        $recent_log = $dbh->selectall_arrayref(
            'SELECT * FROM plugin_sciback_notify_log ORDER BY sent_at DESC LIMIT 30',
            { Slice => {} }
        );
    };

    $template->param(
        enable_checkout      => $self->retrieve_data('enable_checkout')   // 1,
        enable_checkin       => $self->retrieve_data('enable_checkin')    // 1,
        enable_renewal       => $self->retrieve_data('enable_renewal')    // 1,
        from_address         => $self->retrieve_data('from_address')
            // C4::Context->preference('KohaAdminEmailAddress') // '',
        fallback_to_queue    => $self->retrieve_data('fallback_to_queue') // 1,
        smtp_timeout         => $self->retrieve_data('smtp_timeout')      // 8,

        subject_checkout     => $self->retrieve_data('subject_checkout')
            // $self->_default_subject('checkout'),
        subject_checkin      => $self->retrieve_data('subject_checkin')
            // $self->_default_subject('checkin'),
        subject_renewal      => $self->retrieve_data('subject_renewal')
            // $self->_default_subject('renewal'),
        body_checkout        => $self->retrieve_data('body_checkout')
            // $self->_default_body('checkout'),
        body_checkin         => $self->retrieve_data('body_checkin')
            // $self->_default_body('checkin'),
        body_renewal         => $self->retrieve_data('body_renewal')
            // $self->_default_body('renewal'),

        # SMS
        enable_sms_checkout  => $self->retrieve_data('enable_sms_checkout') // 1,
        enable_sms_checkin   => $self->retrieve_data('enable_sms_checkin')  // 1,
        enable_sms_renewal   => $self->retrieve_data('enable_sms_renewal')  // 1,
        sms_hub_url          => $self->retrieve_data('sms_hub_url')         // '',
        sms_hub_apikey       => $self->retrieve_data('sms_hub_apikey')      // '',
        sms_checkout         => $self->retrieve_data('sms_checkout')
            // $self->_default_sms('checkout'),
        sms_checkin          => $self->retrieve_data('sms_checkin')
            // $self->_default_sms('checkin'),
        sms_renewal          => $self->retrieve_data('sms_renewal')
            // $self->_default_sms('renewal'),

        plugin_version       => $VERSION,
        recent_log           => $recent_log,
        CLASS                => $self->{'metadata'}->{'class'},
        PLUGIN_DIR           => $self->bundle_path,
    );

    print $cgi->header( -type => 'text/html', -charset => 'UTF-8' );
    print $template->output;
}

# ─── Ciclo de vida ────────────────────────────────────────────────────────────

sub install {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do(q{
        CREATE TABLE IF NOT EXISTS plugin_sciback_notify_log (
            id              INT AUTO_INCREMENT PRIMARY KEY,
            action          VARCHAR(20)  NOT NULL,
            channel         VARCHAR(10)  NOT NULL DEFAULT 'email',
            borrowernumber  INT          NOT NULL,
            itemnumber      INT,
            to_address      VARCHAR(200) NOT NULL,
            status          VARCHAR(30)  NOT NULL DEFAULT 'sent',
            error_message   TEXT,
            sent_at         DATETIME     NOT NULL,
            INDEX idx_borrowernumber (borrowernumber),
            INDEX idx_sent_at (sent_at),
            INDEX idx_channel (channel)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    });

    $self->store_data({
        enable_checkout     => 1,
        enable_checkin      => 1,
        enable_renewal      => 1,
        fallback_to_queue   => 1,
        smtp_timeout        => 8,
        from_address        => C4::Context->preference('KohaAdminEmailAddress') // '',
        enable_sms_checkout => 1,
        enable_sms_checkin  => 1,
        enable_sms_renewal  => 1,
    });

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;

    # 1.0.0 → 1.1.0: agregar columna channel al log
    my ($col_exists) = $dbh->selectrow_array(
        "SELECT COUNT(*) FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE()
           AND TABLE_NAME   = 'plugin_sciback_notify_log'
           AND COLUMN_NAME  = 'channel'"
    );
    unless ($col_exists) {
        $dbh->do(q{
            ALTER TABLE plugin_sciback_notify_log
            ADD COLUMN channel VARCHAR(10) NOT NULL DEFAULT 'email'
                AFTER action,
            ADD INDEX idx_channel (channel)
        });
    }

    # Defaults SMS si no existen
    $self->store_data({ enable_sms_checkout => 1 })
        unless defined $self->retrieve_data('enable_sms_checkout');
    $self->store_data({ enable_sms_checkin  => 1 })
        unless defined $self->retrieve_data('enable_sms_checkin');
    $self->store_data({ enable_sms_renewal  => 1 })
        unless defined $self->retrieve_data('enable_sms_renewal');

    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;
    my $dbh = C4::Context->dbh;
    $dbh->do('DROP TABLE IF EXISTS plugin_sciback_notify_log');
    return 1;
}

# ─── Templates por defecto ────────────────────────────────────────────────────

sub _default_subject {
    my ( $self, $action ) = @_;
    my %subjects = (
        checkout => 'Préstamo registrado: <<biblio.title>>',
        checkin  => 'Devolución registrada: <<biblio.title>>',
        renewal  => 'Renovación registrada: <<biblio.title>>',
    );
    return $subjects{$action} // 'Notificación de biblioteca';
}

sub _default_body {
    my ( $self, $action ) = @_;

    my $library = '<<library_name>>';
    my $opac    = '<<opac_url>>';

    if ( $action eq 'checkout' ) {
        return <<BODY;
<<nombre_completo>>,

Tu préstamo ha sido registrado.

  Título:    <<biblio.title>>
  Autor:     <<biblio.author>>
  Código:    <<items.barcode>>
  Signatura: <<items.itemcallnumber>>
  Sede:      <<branches.branchname>>

  VENCE: <<checkout.date_due>>

Puedes ver tus préstamos en: $opac

$library
BODY
    }
    elsif ( $action eq 'checkin' ) {
        return <<BODY;
<<nombre_completo>>,

Tu devolución ha sido registrada.

  Título:    <<biblio.title>>
  Autor:     <<biblio.author>>
  Código:    <<items.barcode>>
  Signatura: <<items.itemcallnumber>>
  Sede:      <<branches.branchname>>

Gracias por devolver el material.
Catálogo en línea: $opac

$library
BODY
    }
    elsif ( $action eq 'renewal' ) {
        return <<BODY;
<<nombre_completo>>,

Tu préstamo ha sido renovado.

  Título:    <<biblio.title>>
  Autor:     <<biblio.author>>
  Código:    <<items.barcode>>
  Signatura: <<items.itemcallnumber>>
  Sede:      <<branches.branchname>>

  NUEVA FECHA: <<checkout.date_due>>

Puedes ver tus préstamos en: $opac

$library
BODY
    }

    return 'Notificación de biblioteca <<library_name>>';
}

sub _default_sms {
    my ( $self, $action ) = @_;
    my %sms = (
        checkout => 'Prestamo: <<biblio.title>> - Vence: <<checkout.date_due>> | <<library_name>>',
        checkin  => 'Devolucion registrada: <<biblio.title>> | <<library_name>>',
        renewal  => 'Renovacion: <<biblio.title>> - Nueva fecha: <<checkout.date_due>> | <<library_name>>',
    );
    return $sms{$action} // 'Notificacion de biblioteca';
}

sub _is_html {
    my ( $self, $body ) = @_;
    return $body =~ /<html|<body|<p |<div|<table/i ? 1 : 0;
}

1;
