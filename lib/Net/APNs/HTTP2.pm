package Net::APNs::HTTP2;
use 5.010;
use strict;
use warnings;

our $VERSION = "0.02";

use Moo;
use Crypt::JWT;
use JSON;
use Cache::Memory::Simple;

use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use Protocol::HTTP2::Client;

has [qw/auth_key auth_password cert_file cert cert_password key_id team_id bundle_id is_development debug/] => (
    is => 'rw',
);

has apns_port => (
    is      => 'rw',
    default => 443, # can use 2197
);

has on_error => (
    is      => 'rw',
    default => sub {
        sub {};
    },
);

sub _host {
    my $self = shift;
    $self->is_development ? 'api.development.push.apple.com' : 'api.push.apple.com';
}

sub _client {
    my $self = shift;
    $self->{_client} ||= Protocol::HTTP2::Client->new(keepalive => 1, 
        on_change_state => sub {
            my ( $stream_id, $previous_state, $current_state ) = @_;
            ## Stream states from Protocol::HTTP2::Constants
            #IDLE        => 1,
            #RESERVED    => 2,
            #OPEN        => 3,
            #HALF_CLOSED => 4,
            #CLOSED      => 5,
            #printf STDERR "HTTP2 protocol stream ($stream_id) changed state ($previous_state -> $current_state) !\n";
        }
    );
}

sub _handle {
    my $self = shift;

    unless ($self->_handle_connected) {
        # NOTE: wrong certificate gives devicetokennotfortopic
        # NOTE: expired certificate gives nothing....
        my $ctx_options = {
                verify          => 1,
                verify_peername => 'https',
        };
                # This is used for provider certificate authentication
        $self->cert_file and $ctx_options->{cert_file} = $self->cert_file;
        $self->cert_password and $ctx_options->{cert_password} = $self->cert_password;
        $self->cert and $ctx_options->{cert} = $self->cert;
        $self->debugf("Connecting to %s", $self->_host);
        my $handle = AnyEvent::Handle->new(
            keepalive => 1,
            connect   => [ $self->_host, $self->apns_port ],
            tls       => 'connect',
            tls_ctx   => $ctx_options,
            autocork => 1,
            on_error => sub {
                my ($handle, $fatal, $message) = @_;
                $self->debugf('STARTTLS ERROR !!!! : %s - %s', $fatal, $message);
                $self->on_error->($fatal, $message);
                $handle->destroy;
                $self->{_condvar}->send;
            },
            on_eof => sub {
                my $handle = shift;
                # TODO: See if we encounter this during testing
                $self->debugf('ON_EOF !!!!');
                $self->{_condvar}->send;
            },
            on_read => sub {
                my $handle = shift;
                $self->_client->feed(delete $handle->{rbuf});
                while (my $frame = $self->_client->next_frame) {
                    $handle->push_write($frame);
                }
                if ($self->_client->shutdown) {
                    $handle->push_shutdown;
                    return;
                }

                unless ($self->_client->{active_streams} > 0) {
                    $self->{_condvar}->send;
                    return;
                }
            },
            on_starttls => sub {
                my ($handle, $success, $message) = @_;
                unless ($success) {
                    # TODO: gracefull exit
                    $handle->destroy;
                    $self->{_connect_error} = $message;
                    $self->{_condvar}->send;
                }
            }
        );

        $self->{_handle} = $handle;
    }

    return $self->{_handle};
}

sub _handle_connected {
    my $self = shift;

    my $handle = $self->{_handle};
    return if !$handle;
    return if $handle->destroyed;
    return 1;
}

sub _provider_authentication_token {
    my $self = shift;

    $self->{_cache} ||= Cache::Memory::Simple->new;
    $self->{_cache}->get_or_set('provider_authentication_token', sub {
        my $craims = {
            iss => $self->team_id,
            iat => time,
        };
        my $jwt = Crypt::JWT::encode_jwt(
            payload       => $craims,
            key           => [ $self->auth_key, $self->auth_password ],
            alg           => 'ES256',
            extra_headers => { kid => $self->key_id },
        );
        return $jwt;
    }, 60 * 50);
}

sub prepare {
    my ($self, $device_token, $payload, $cb, $extra_header) = @_;
    my $apns_expiration  = $extra_header->{apns_expiration} || 0;
    my $apns_priority    = $extra_header->{apns_priority}   || 5;
    my $apns_topic       = $extra_header->{apns_topic}      || $self->bundle_id;
    my $apns_id          = $extra_header->{apns_id};
    my $apns_collapse_id = $extra_header->{apns_collapse_id};
    my $apns_push_type   = $extra_header->{apns_push_type}   || 'alert' || 'background';

    my $headers = {
        'apns-expiration' => $apns_expiration,
        'apns-priority'   => $apns_priority,
        'apns-topic'      => $apns_topic,
        # 'apns-push-type'  => $apns_push_type,
    };
    $headers->{ 'authorization'    } = sprintf('bearer %s', $self->_provider_authentication_token) if $self->auth_key;
    $headers->{ 'apns-id'          } = $apns_id if defined $apns_id;
    $headers->{ 'apns-collapse-id' } = $apns_collapse_id if defined $apns_collapse_id;

    my $client = $self->_client;
    $self->debugf("Preparing request for %s", $device_token);
    $client->request(
        ':scheme'    => 'https',
        ':authority' => join(':', $self->_host, $self->apns_port),
        ':path'      => sprintf('/3/device/%s', $device_token),
        ':method'    => 'POST',
        headers      => [ %$headers ],
        data         => JSON::encode_json($payload),
        on_done      => $cb,
    );

    return $self;
}

sub connected {
    my $self = shift;
    return $self->_handle_connected || $self->{_connect_error};
}

sub send {
    my $self = shift;

    local $self->{_condvar} = AnyEvent->condvar;

    my $handle = $self->_handle;
    my $client = $self->_client;
    my $framectr = 0;
    $self->debugf("Sending frames...");
    while (my $frame = $client->next_frame) {
        $handle->push_write($frame);
        $framectr++;
    }
    $self->debugf("Done sending $framectr frames...");

    $self->{_condvar}->recv;

    return 1;
}

sub close {
    my $self = shift;
    $self->debugf("Closing connection to APNS...");
    if ($self->{_client} && !$self->{_client}->shutdown) {
        $self->{_client}->close;
    }
    if ($self->{_handle} && !$self->{_handle}->destroyed) {
        $self->{_handle}->destroy;
    }
    delete $self->{_cache};
    delete $self->{_handle};
    delete $self->{_client};

    return 1;
}


sub debugf {
        my ($self) = shift;
        $self->{debug} and printf STDERR "APNS: ".shift."\n",@_;
}

1;
__END__

=encoding utf-8

=head1 NAME

Net::APNs::HTTP2 - APNs Provider API for Perl

=head1 SYNOPSIS

    use Net::APNs::HTTP2;

    my %opts;

    $opts = {
        is_development => 1,
        cert_file      => '/path/to/pushcertificate.pem',
        cert_password  => 'mykeysecret',
        key_id         => $key_id,
        team_id        => $team_id,
        bundle_id      => $bundle_id,
    };

    #
    # Use auth_key, auth_password, key_id, team_id
    # if you want to use provider token based authentication
    # (using JWT)
    #
    $opts = {
        is_development => 1,
        auth_key       => '/path/to/auth_key.p8.pem',
        auth_password  => 'mykeysecret',
        key_id         => $key_id,
        team_id        => $team_id,
        bundle_id      => $bundle_id,
    };

    my $apns = Net::APNs::HTTP2->new( %opts );

    while (1) {
        $apns->prepare($device_token, {
            aps => {
                alert => 'some message',
                badge => 1,
            },
        }, sub {
            my ($header, $content) = @_;
            # $header = [
            #     ":status" => "200",
            #     "apns-id" => "82B34E17-370A-DBF4-5046-FF56A4EA1FAF",
            # ];
            ...
        });

        # You can chainged
        $apns->prepare(...)->prepare(...)->prepare(...);

        # send all prepared requests in parallel
        $apns->send;

        # do something
    }

    # must call `close` when finished
    $apns->close;

=head1 DESCRIPTION

Net::APNs::HTTP2 is APNs Provider API for Perl.

=head1 METHODS

=head2 new(%args)

Create a new instance of C<< Net::APNs::HTTP2 >>.

Supported arguments are:

=over

=item auth_key : File Path

Universal Push Notification Client SSL Certificate.
But, can not use this auth key as it is.
Please convert key as follows:

  openssl pkcs8 -in AuthKey_XXXXXXXXXX.p8 -inform PEM -out auth_key.p8 -outform PEM -nocrypt

=item auth_password : Str

Password (optional) for the Universal Push Notification Client SSL Certificate.

=item cert_file : File Path

APNS Provider certificate.
This should be in PEM format, or any other format the underlying Crypt code can handle.

=item cert : Str

APNS Provider certificate in PEM format as a string.

=item cert_password : Str

Password (optional) for the Provider certificate

=item key_id : Str

A 10-character key identifier (kid) key, obtained from your developer account.

=item team_id : Str

The issuer (iss) registered claim key, whose value is your 10-character Team ID, obtained from your developer account.

=item bundle_id : Str

Your Application bundle identifier.

=item is_development : Bool

Development server: api.development.push.apple.com:443
Production server: api.push.apple.com:443

=back

=head2 $apns->prepare($device_token, $payload, $callback [, $extra_headers ])

Create a request.

  $apns->prepare($device_token, {
      aps => {
         alert => {
            title => 'test message',
            body  => 'from Net::APNs::HTTP2',
         },
         badge => 1,
      },
  }, sub {
      my ($header, $content) = @_;
      # $header = [
      #     ":status" => "200",
      #     "apns-id" => "82B34E17-370A-DBF4-5046-FF56A4EA1FAF",
      # ];
      ...
  });

You can chain calls

  $apns->prepare(...)->prepare(...)->prepare(...)->send();

=head2 $apns->send()

Send notification.

=head2 $apns->close()

Close connections.

=head1 LICENSE

Copyright (C) xaicron.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

xaicron E<lt>xaicron@gmail.comE<gt>

=head1 CONTRIBUTORS

Edward van der Jagt E<lt>edward@caret.netE<gt>

=cut

