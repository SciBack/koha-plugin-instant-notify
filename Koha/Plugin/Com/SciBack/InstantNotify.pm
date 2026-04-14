package Koha::Plugin::Com::SciBack::InstantNotify;

# SciBack Instant Notify — Koha Plugin
# Envía notificaciones de email en tiempo real para transacciones de circulación
# (checkout, checkin, renewal) sin depender del cron de message_queue.
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

our $VERSION = '1.0.0';

our $metadata = {
    name            => 'SciBack Instant Notify',
    author          => 'SciBack <soporte@sciback.pe>',
    description     => 'Notificaciones instantáneas de circulación vía email (checkout, devolución, renovación). Producto SciBack.',
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

    # Verificar habilitación por tipo de acción
    return unless $self->retrieve_data("enable_$action");

    # Patron — puede ser undef si fue anonimizado (privacy=2 en checkin)
    my $patron = try { $checkout->patron } catch { return };
    return unless $patron && $patron->email;

    # Item — puede ser undef si el ítem fue eliminado (especialmente en checkin)
    my $item = try { $checkout->item } catch { return };
    return unless $item;

    # Biblio
    my $biblio = try { $item->biblio } catch { undef };

    # Construir y enviar el email
    my $data = {
        action   => $action,
        patron   => $patron,
        item     => $item,
        biblio   => $biblio,
        checkout => $checkout,
    };

    $self->_send_notification($data);

    return;
}

# ─── Envío de email ────────────────────────────────────────────────────────────

sub _send_notification {
    my ( $self, $data ) = @_;

    my $action  = $data->{action};
    my $patron  = $data->{patron};
    my $item    = $data->{item};
    my $biblio  = $data->{biblio};
    my $checkout = $data->{checkout};

    my $title    = $biblio ? $biblio->title   : 'Ítem';
    my $author   = $biblio ? $biblio->author  : '';
    my $barcode  = $item->barcode // '';
    my $callnum  = $item->itemcallnumber // '';
    my $nombre   = join( ' ', grep { $_ } $patron->firstname, $patron->surname );
    my $cardnum  = $patron->cardnumber // '';
    my $to_email = $patron->email;

    # Fecha de vencimiento (solo checkout y renewal)
    my $date_due_str = '';
    if ( $action ne 'checkin' ) {
        my $date_due = try { $checkout->date_due } catch { undef };
        if ($date_due) {
            try {
                # date_due puede ser string o DateTime según el contexto
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
                $date_due_str = "$date_due";  # fallback: usar string tal cual
            };
        }
    }

    # Branch
    my $branch_name = '';
    try {
        require Koha::Libraries;
        my $branch_code = $checkout->branchcode // $item->holdingbranch // '';
        if ($branch_code) {
            my $library = Koha::Libraries->find($branch_code);
            $branch_name = $library->branchname if $library;
        }
    };

    # Obtener templates personalizados o usar defaults
    my $subject_tpl = $self->retrieve_data("subject_$action")
        // $self->_default_subject($action);
    my $body_tpl = $self->retrieve_data("body_$action")
        // $self->_default_body($action);

    # Reemplazar variables en templates
    my %vars = (
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

    my $subject = $subject_tpl;
    my $body    = $body_tpl;
    for my $var ( keys %vars ) {
        my $val = $vars{$var} // '';
        $subject =~ s/\Q$var\E/$val/g;
        $body    =~ s/\Q$var\E/$val/g;
    }

    # Enviar
    my $from = $self->retrieve_data('from_address')
        // C4::Context->preference('KohaAdminEmailAddress')
        // '';

    return unless $from && $to_email;

    my $sent = 0;
    my $error_msg = '';

    try {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm( $self->retrieve_data('smtp_timeout') // 8 );

        # Forzar UTF-8 en strings para evitar doble-encoding
        utf8::decode($subject) unless utf8::is_utf8($subject);
        utf8::decode($body)    unless utf8::is_utf8($body);

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

        # Fallback a message_queue si está habilitado
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
                $sent = 2;  # 2 = enqueued fallback
            };
        }
    };

    # Log
    $self->_log_notification({
        action           => $action,
        borrowernumber   => $patron->borrowernumber,
        itemnumber       => $item->itemnumber,
        to_address       => $to_email,
        status           => $sent == 1 ? 'sent' : ( $sent == 2 ? 'queued_fallback' : 'failed' ),
        error_message    => $error_msg,
    });

    return $sent;
}

# ─── Log ──────────────────────────────────────────────────────────────────────

sub _log_notification {
    my ( $self, $args ) = @_;
    try {
        my $dbh = C4::Context->dbh;
        $dbh->do(
            'INSERT INTO plugin_sciback_notify_log
             (action, borrowernumber, itemnumber, to_address, status, error_message, sent_at)
             VALUES (?, ?, ?, ?, ?, ?, NOW())',
            undef,
            $args->{action},
            $args->{borrowernumber},
            $args->{itemnumber},
            $args->{to_address},
            $args->{status},
            $args->{error_message} // '',
        );
    };
}

# ─── Configuración ────────────────────────────────────────────────────────────

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    if ( $cgi->param('save') ) {
        $self->store_data({
            enable_checkout  => scalar( $cgi->param('enable_checkout') )  ? 1 : 0,
            enable_checkin   => scalar( $cgi->param('enable_checkin') )   ? 1 : 0,
            enable_renewal   => scalar( $cgi->param('enable_renewal') )   ? 1 : 0,
            from_address     => scalar( $cgi->param('from_address') )     // '',
            fallback_to_queue => scalar( $cgi->param('fallback_to_queue') ) ? 1 : 0,
            smtp_timeout     => int( scalar( $cgi->param('smtp_timeout') ) || 8 ),
            subject_checkout => scalar( $cgi->param('subject_checkout') ) // '',
            subject_checkin  => scalar( $cgi->param('subject_checkin') )  // '',
            subject_renewal  => scalar( $cgi->param('subject_renewal') )  // '',
            body_checkout    => scalar( $cgi->param('body_checkout') )    // '',
            body_checkin     => scalar( $cgi->param('body_checkin') )     // '',
            body_renewal     => scalar( $cgi->param('body_renewal') )     // '',
        });
        print $cgi->redirect( -uri => $cgi->referer || '/cgi-bin/koha/plugins/plugins-home.pl' );
        return;
    }

    my $template = $self->get_template({ file => 'configure.tt' });

    # Log reciente
    my $recent_log = [];
    try {
        my $dbh = C4::Context->dbh;
        $recent_log = $dbh->selectall_arrayref(
            'SELECT * FROM plugin_sciback_notify_log ORDER BY sent_at DESC LIMIT 20',
            { Slice => {} }
        );
    };

    $template->param(
        enable_checkout   => $self->retrieve_data('enable_checkout')  // 1,
        enable_checkin    => $self->retrieve_data('enable_checkin')   // 1,
        enable_renewal    => $self->retrieve_data('enable_renewal')   // 1,
        from_address      => $self->retrieve_data('from_address')
            // C4::Context->preference('KohaAdminEmailAddress') // '',
        fallback_to_queue => $self->retrieve_data('fallback_to_queue') // 1,
        smtp_timeout      => $self->retrieve_data('smtp_timeout')      // 8,

        subject_checkout  => $self->retrieve_data('subject_checkout')
            // $self->_default_subject('checkout'),
        subject_checkin   => $self->retrieve_data('subject_checkin')
            // $self->_default_subject('checkin'),
        subject_renewal   => $self->retrieve_data('subject_renewal')
            // $self->_default_subject('renewal'),

        body_checkout     => $self->retrieve_data('body_checkout')
            // $self->_default_body('checkout'),
        body_checkin      => $self->retrieve_data('body_checkin')
            // $self->_default_body('checkin'),
        body_renewal      => $self->retrieve_data('body_renewal')
            // $self->_default_body('renewal'),

        plugin_version    => $VERSION,
        recent_log        => $recent_log,
        CLASS             => $self->{'metadata'}->{'class'},
        PLUGIN_DIR        => $self->bundle_path,
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
            borrowernumber  INT          NOT NULL,
            itemnumber      INT,
            to_address      VARCHAR(200) NOT NULL,
            status          VARCHAR(30)  NOT NULL DEFAULT 'sent',
            error_message   TEXT,
            sent_at         DATETIME     NOT NULL,
            INDEX idx_borrowernumber (borrowernumber),
            INDEX idx_sent_at (sent_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
    });

    # Valores por defecto
    $self->store_data({
        enable_checkout   => 1,
        enable_checkin    => 1,
        enable_renewal    => 1,
        fallback_to_queue => 1,
        smtp_timeout      => 8,
        from_address      => C4::Context->preference('KohaAdminEmailAddress') // '',
    });

    return 1;
}

sub upgrade {
    my ( $self, $args ) = @_;
    # Migraciones futuras por versión
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
Estimado/a <<nombre_completo>>,

Su préstamo ha sido registrado exitosamente.

  Título:        <<biblio.title>>
  Autor:         <<biblio.author>>
  Código:        <<items.barcode>>
  Vence:         <<checkout.date_due>>
  Sede:          <<branches.branchname>>

Por favor devuelva el material antes de la fecha de vencimiento.
Puede consultar sus préstamos en: $opac

$library
BODY
    }
    elsif ( $action eq 'checkin' ) {
        return <<BODY;
Estimado/a <<nombre_completo>>,

La devolución de su material ha sido registrada exitosamente.

  Título:  <<biblio.title>>
  Autor:   <<biblio.author>>
  Código:  <<items.barcode>>
  Sede:    <<branches.branchname>>

Gracias por devolver su material a tiempo.
Puede explorar nuestro catálogo en: $opac

$library
BODY
    }
    elsif ( $action eq 'renewal' ) {
        return <<BODY;
Estimado/a <<nombre_completo>>,

Su préstamo ha sido renovado exitosamente.

  Título:         <<biblio.title>>
  Autor:          <<biblio.author>>
  Código:         <<items.barcode>>
  Nueva fecha:    <<checkout.date_due>>
  Sede:           <<branches.branchname>>

$library
BODY
    }

    return 'Notificación de biblioteca <<library_name>>';
}

sub _is_html {
    my ( $self, $body ) = @_;
    return $body =~ /<html|<body|<p |<div|<table/i ? 1 : 0;
}

1;
