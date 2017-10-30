[![Build Status](https://travis-ci.org/xaicron/p5-Net-APNs-HTTP2.svg?branch=master)](https://travis-ci.org/xaicron/p5-Net-APNs-HTTP2)
# NAME

Net::APNs::HTTP2 - APNs Provider API for Perl

# SYNOPSIS

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

# DESCRIPTION

Net::APNs::HTTP2 is APNs Provider API for Perl.

# METHODS

## new(%args)

Create a new instance of `Net::APNs::HTTP2`.

Supported arguments are:

- auth\_key : File Path

    Universal Push Notification Client SSL Certificate.
    But, can not use this auth key as it is.
    Please convert key as follows:

        openssl pkcs8 -in AuthKey_XXXXXXXXXX.p8 -inform PEM -out auth_key.p8 -outform PEM -nocrypt

- auth_password : Str

    Password (optional) for the Universal Push Notification Client SSL Certificate.

- cert\_file : File Path

    APNS Provider certificate.
    This should be in PEM format, or any other format the underlying Crypt code can handle.

- cert : Str

    APNS Provider certificate in PEM format as a string.

- cert_password : Str

    Password (optional) for the Provider certificate

- key\_id : Str

    A 10-character key identifier (kid) key, obtained from your developer account.

- team\_id : Str

    The issuer (iss) registered claim key, whose value is your 10-character Team ID, obtained from your developer account.

- bundle\_id : Str

    Your Application bundle identifier.

- is\_development : Bool

    Development server: api.development.push.apple.com:443
    Production server: api.push.apple.com:443

## $apns->prepare($device\_token, $payload, $callback \[, $extra\_headers \])

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

## $apns->send()

Send notification.

## $apns->close()

Close connections.

# LICENSE

Copyright (C) xaicron.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

xaicron <xaicron@gmail.com>

# CONTRIBUTORS

Edward van der Jagt <edward@caret.net>
