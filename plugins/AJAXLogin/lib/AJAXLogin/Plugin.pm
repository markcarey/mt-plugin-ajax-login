package AJAXLogin::Plugin;

use strict;

sub ajax_login {
    my $app     = shift;
    my $q       = $app->param;
    my $name    = $q->param('username');
    my $blog_id = $q->param('blog_id');
    my $blog    = MT->model('blog')->load($blog_id)
      or return $app->error(
        $app->translate( 'Can\'t load blog #[_1].', $blog_id ) );
    my $auths = $blog->commenter_authenticators;
    if ( $auths !~ /MovableType/ ) {
        $app->log(
            {
                message => $app->translate(
'Invalid commenter login attempt from [_1] to blog [_2](ID: [_3]) which does not allow Movable Type native authentication.',
                    $name, $blog->name, $blog_id
                ),
                level    => MT::Log::WARNING(),
                category => 'login_commenter',
            }
        );
        return _send_json_response( $app,
            { status => 0, message => $app->translate('Invalid login.') } );
    }

    require MT::Auth;
    my $ctx = MT::Auth->fetch_credentials( { app => $app } );
    $ctx->{blog_id} = $blog_id;
    my $result = MT::Auth->validate_credentials($ctx);
    my ( $message, $error );
    if (   ( MT::Auth::NEW_LOGIN() == $result )
        || ( MT::Auth::NEW_USER() == $result )
        || ( MT::Auth::SUCCESS() == $result ) )
    {
        my $commenter = $app->user;
        if ( $q->param('external_auth') && !$commenter ) {
            $app->param( 'name', $name );
            if ( MT::Auth::NEW_USER() == $result ) {
                $commenter =
                  $app->_create_commenter_assign_role( $q->param('blog_id') );
                return $app->login_form(
                    error => $app->translate('Invalid login') )
                  unless $commenter;
            }
            elsif ( MT::Auth::NEW_LOGIN() == $result ) {
                my $registration = $app->config->CommenterRegistration;
                unless (
                       $registration
                    && $registration->{Allow}
                    && (   $app->config->ExternalUserManagement
                        || $blog->allow_commenter_regist )
                  )
                {
                    return $app->login_form(
                        error => $app->translate(
'Successfully authenticated but signing up is not allowed.  Please contact system administrator.'
                        )
                    ) unless $commenter;
                }
                else {
                    return $app->signup(
                        error => $app->translate('You need to sign up first.') )
                      unless $commenter;
                }
            }
        }
        MT::Auth->new_login( $app, $commenter );
        if ( $app->_check_commenter_author( $commenter, $blog_id ) ) {
            my $session_key = $app->make_commenter_session($commenter);
            my $session_state = session_state($session_key, $commenter, $blog, $blog_id);
            return _send_json_response( $app,
                { status => 1, message => "session created",
                  session_key => $session_key,
                  user => $session_state } );

            #return $app->redirect_to_target;
        }
        $error = $app->translate("Permission denied.");
        $message =
          $app->translate( "Login failed: permission denied for user '[_1]'",
            $name );
    }
    elsif ( MT::Auth::INVALID_PASSWORD() == $result ) {
        $message =
          $app->translate( "Login failed: password was wrong for user '[_1]'",
            $name );
    }
    elsif ( MT::Auth::INACTIVE() == $result ) {
        $message =
          $app->translate( "Failed login attempt by disabled user '[_1]'",
            $name );
    }
    else {
        $message =
          $app->translate( "Failed login attempt by unknown user '[_1]'",
            $name );
    }
    $app->log(
        {
            message  => $message,
            level    => MT::Log::WARNING(),
            category => 'login_commenter',
        }
    );
    $ctx->{app} ||= $app;
    MT::Auth->invalidate_credentials($ctx);
    my $response = {
        status  => $result,
        message => $error || $app->translate("Invalid login"),
    };
    return _send_json_response( $app, $response );

}

#modified from MT::App::session_state
sub session_state {
    my ( $session_key, $commenter, $blog, $blog_id ) = @_;
    my $c;
    
    if ( $session_key && $commenter ) {
        $c = {
            sid     => $session_key,
            name    => $commenter->nickname || '(Display Name not set)',
            url     => $commenter->url,
            email   => $commenter->email,
            userpic => scalar $commenter->userpic_url,
            profile => "",                              # profile link url
            is_authenticated => 1,
            is_author =>
                ( $commenter->type == MT::Author::AUTHOR() ? 1 : 0 ),
            is_trusted       => 0,
            is_anonymous     => 0,
            can_post         => 0,
            can_comment      => 0,
            is_banned        => 0,
        };
        if ( $blog_id && $blog ) {
            my $blog_perms = $commenter->blog_perm($blog_id);
            my $banned = $commenter->is_banned($blog_id) ? 1 : 0;
            $banned = 0 if $blog_perms && $blog_perms->can_administer;
            $banned ||= 1 if $commenter->status == MT::Author::BANNED();
            $c->{is_banned} = $banned;

            # FIXME: These may not be accurate in 'SingleCommunity' mode...
            my $can_comment = $banned ? 0 : 1;
            $can_comment = 0
                unless $blog->allow_unreg_comments
                    || $blog->allow_reg_comments;
            $c->{can_comment} = $can_comment;
            $c->{can_post}
                = ( $blog_perms && $blog_perms->can_create_post ) ? 1 : 0;
            $c->{is_trusted} =
                ( $commenter->is_trusted($blog_id) ? 1 : 0 ),
        }
    }

    unless ($c) {
        my $can_comment = $blog && $blog->allow_anon_comments ? 1 : 0;
        $c = {
            is_authenticated => 0,
            is_trusted       => 0,
            is_anonymous     => 1,
            can_post         => 0,            # no anonymous posts
            can_comment      => $can_comment,
            is_banned        => 0,
        };
    }

    return $c;
}

sub _send_json_response {
    my ( $app, $result ) = @_;
    require JSON;
    my $json = JSON::objToJson($result);
    $app->send_http_header("");
    $app->print($json);
    return $app->{no_print_body} = 1;
    return undef;
}

1;
__END__