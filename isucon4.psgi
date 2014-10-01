use 5.20.0;
use utf8;
use IO::Handle;
use POSIX qw/strftime/;
use JSON::XS;
use URI::Escape::XS qw/uri_unescape/;
use IO::File::WithPath;

my $uri_base = 'http://localhost';

my $header = ['content-type' => 'text/html'];
my $user_lock_threshold = $ENV{'ISU4_USER_LOCK_THRESHOLD'} || 3;
my $ip_ban_threshold = $ENV{'ISU4_IP_BAN_THRESHOLD'} || 10;

my $users = +{};
my $ips = +{};
my $banned_ips = +{};
my $locked_users = +{};
my $add_logs = [];

my $mysessionstore = +{};

my $user_log_file = '/home/isucon/sql/dummy_users.tsv';
my $user_used_log_file = '/home/isucon/sql/dummy_users_used.tsv';
my $user_used_add_log_file = '/home/isucon/sql/dummy_users_used_add.tsv';
my $user_used_add_warmup_log_file = '/home/isucon/sql/dummy_users_used_add_warmup.tsv';

my $user_used_add_log;

our $log_read_mode = 0;
{
    local $log_read_mode = 1;
    # preload
    if ( -e $user_log_file ) {
        open my $user_log, '<', $user_log_file;
        my @lines = <$user_log>;
        $user_log->close;
        for my $line (@lines) {
            chomp $line;
            my ($id, $login, $pass) = split/\t/, $line;
            my $user = {login => $login, password => $pass, count => 0};
            $users->{$login} = $user;
        }
    }

    {
        # warmup
        if ( -e $user_used_add_warmup_log_file ) {
            open my $user_used_add_warmup_log, '<', $user_used_add_warmup_log_file;
            my @lines = <$user_used_add_warmup_log>;
            $user_used_add_warmup_log->close;
            for my $line (@lines) {
                chomp $line;
                my ($created_at, $login, $ip, $succeeded) = split/\t/, $line;
                add_log($created_at, $login, $ip, $succeeded);
            }
            # cleanup
            $locked_users = +{};
            $banned_ips = +{};
            $ips = +{};
            for my $login ( keys $users ) {
                $users->{$login}{count} = 0;
            }
        }
    }

    if ( -e $user_used_log_file ) {
        open my $user_used_log, '<', $user_used_log_file;
        my @lines = <$user_used_log>;
        $user_used_log->close;
        for my $line (@lines) {
            chomp $line;
            my ($id, $login, $count) = split/\t/, $line;
            my $user = $users->{$login} or next;
            $user->{count} = $count;
            if ( $count >= $user_lock_threshold ) {
                $locked_users->{$login} = 1;
            }
        }
    }

    if ( -e $user_used_add_log_file ) {
        open $user_used_add_log, '<', $user_used_add_log_file;
        my @lines = <$user_used_add_log>;
        $user_used_add_log->close;
        for my $line (@lines) {
            chomp $line;
            my ($created_at, $login, $ip, $succeeded) = split/\t/, $line;
            add_log($created_at, $login, $ip, $succeeded);
        }
        open $user_used_add_log, '>>', $user_used_add_log_file;
    }
    else {
        open $user_used_add_log, '>', $user_used_add_log_file;
    }
}
$log_read_mode = 0;

sub add_log {
    my ($time, $login, $ip, $succeeded) = @_;
    if ( !$log_read_mode ) {
        push $add_logs, [$time, $login, $ip, $succeeded];
    }
    my $user = $users->{$login};
    my $ip_count = $ips->{$ip} // 0;
    if ( $succeeded ) {
        if ( $user ) {
            $user->{count} = 0;
            $user->{last_login1} = $user->{last_login2};
            $user->{last_login2} = $time;
            $user->{last_ip1} = $user->{last_ip2};
            $user->{last_ip2} = $ip;
            delete $locked_users->{$login};
        }
        delete $ips->{$ip};
    }
    else {
        if ( $user ) {
            $user->{count}++;
            if ( $user->{count} >= $user_lock_threshold ) {
                $locked_users->{$login} = 1;
            }
        }
        $ip_count++;
        $ips->{$ip} = $ip_count;
        if ( $ip_count >= $ip_ban_threshold ) {
            $banned_ips->{$ip} = 1;
        }
    }
}


sub base_top() {q{<!DOCTYPE html><html><head><meta charset="UTF-8"><title>isucon4</title></head><body><script>document.write(' <link rel="stylesheet" href="/stylesheets/bootstrap.min.css"><link rel="stylesheet" href="/stylesheets/bootflat.min.css"><link rel="stylesheet" href="/stylesheets/isucon-bank.css"> ')</script><div class="container"><h1 id="topbar"><a href="/"><script>document.write('<img src="/images/isucon-bank.png" alt="いすこん銀行 オンラインバンキングサービス">')</script></a></h1>}}

sub base_bottom() {q{</div></body></html>}}

sub mypage {
    my $env = shift;
    my $user = $env->{user};

    sprintf(
        q{<div class="alert alert-success" role="alert"> ログインに成功しました。<br>未読のお知らせが０件、残っています。</div><dl class="dl-horizontal"><dt>前回ログイン</dt><dd id="last-logined-at">%s</dd><dt>最終ログインIPアドレス</dt><dd id="last-logined-ip">%s</dd></dl><div class="panel panel-default"><div class="panel-heading"> お客様ご契約ID：%s 様の代表口座 </div><div class="panel-body"><div class="row"><div class="col-sm-4"> 普通預金<br><small>東京支店　1111111111</small><br></div><div class="col-sm-4"><p id="zandaka" class="text-right"> ―――円 </p></div><div class="col-sm-4"><p><a class="btn btn-success btn-block">入出金明細を表示</a><a class="btn btn-default btn-block">振込・振替はこちらから</a></p></div><div class="col-sm-12"><a class="btn btn-link btn-block">定期預金・住宅ローンのお申込みはこちら</a></div></div></div></div></div>},
        $user->{last_login1} ? strftime('%Y-%m-%d %H:%M:%S', localtime($user->{last_login1})) : '',
        $user->{last_ip1},
        $user->{login}
    );
}

sub set_flash {
    my $msg_id = shift;
    
    return ['302', [Location => "${uri_base}/", 'Set-Cookie' => "isu4_flash=$msg_id; path=/; HttpOnly"], []];
}

sub _generate_sid {
    use Digest::SHA1;
    return Digest::SHA1::sha1_hex(rand() . $$ . {} . time);
}

sub post_login {
    my $env = shift;

    my $param    = $env->{param};
    my $login    = $param->{login};
    my $password = $param->{password};
    my $user     = $users->{$login};

    if ( $env->{'HTTP_X_FORWARDED_FOR'} ) {
        my ( $ip, ) = $env->{HTTP_X_FORWARDED_FOR} =~ /([^,\s]+)$/;
        $env->{REMOTE_ADDR} = $ip;
    }
    my $ip = $env->{REMOTE_ADDR};

    if ( exists $banned_ips->{$ip} ) {
        add_log(time, $login, $ip, 0);
        return set_flash(2); # You're banned.
    }
    if ( exists $locked_users->{$login} ) {
        add_log(time, $login, $ip, 0);
        return set_flash(1); # This account is locked.
    }

    if ( $user && $user->{password} eq $password ) {
        add_log(time, $login, $ip, 1);

        my $sid = _generate_sid();
        $mysessionstore->{$sid} = $user;
        return ['302', [Location => "${uri_base}/mypage", 'Set-Cookie' => "isu4_session=$sid; path=/; HttpOnly"], []];
    }

    add_log(time, $login, $ip, 0);
    return set_flash(3); # Wrong username or password
}

sub app {
    my $env = shift;
    my $method    = $env->{REQUEST_METHOD};
    my $path_info = $env->{PATH_INFO};

    $uri_base = 'http://' . $env->{HTTP_HOST};

    if ( $method eq 'GET' ) {
        if ( $path_info eq '/mypage' ) {
            my $sid  = $env->{'psgix.nginx_request'}->variable('cookie_isu4_session');
            my $user = $mysessionstore->{$sid};
 
            if ( $user ) {
                $env->{user} = $user;
                return ['200', $header, [
                    base_top(),
                    mypage($env),
                    base_bottom(),
                ]];
            }
            return ['302', [Location => "${uri_base}/"], []];
        }
        elsif ( $path_info eq '/report' ) {
            for my $add_log ( @$add_logs ) {
                $user_used_add_log->printflush(join("\t", @$add_log), "\n");
            }
            $add_logs = [];
            return ['200', ['Content-Type' => 'application/json'], [
                encode_json({
                    banned_ips => [keys $banned_ips],
                    locked_users => [keys $locked_users],
                })
            ]];
        }
    }
    elsif ( $method eq 'POST' && $path_info eq '/login' ) {
        my $input = delete $env->{'psgi.input'};
        my $body = '';
        $input->read($body, $env->{CONTENT_LENGTH});
        $env->{param} = { map { split('=',$_,2) } split('&',$body)};
        for ( values $env->{param} ) {
            s/\+/ /g;
            $_ = uri_unescape($_);
        }

        return post_login($env);
    }

    return ['404', $header, ['not found']];
}


\&app;

