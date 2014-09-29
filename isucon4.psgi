use 5.20.0;
use utf8;
use IO::Handle;
use Encode;
use POSIX qw/strftime/;
use JSON::XS;
use URI::Escape::XS qw/uri_unescape/;
use IO::File::WithPath;

my $uri_base = 'http://localhost';

my $flashs = [
    'This account is locked.',
    q{You're banned.},
    'Wrong username or password',
    'You must be logged in',
];

my $header = ['content-type' => 'text/html'];
my $user_lock_threshold = $ENV{'ISU4_USER_LOCK_THRESHOLD'} || 3;
my $ip_ban_threshold = $ENV{'ISU4_IP_BAN_THRESHOLD'} || 10;

my $users = +{};
my $ips = +{};
my $banned_ips = +{};
my $locked_users = +{};

my $mysessionstore = +{};

my $user_log_file = '/home/isucon/sql/dummy_users.tsv';
my $user_used_log_file = '/home/isucon/sql/dummy_users_used.tsv';
my $user_used_add_log_file = '/home/isucon/sql/dummy_users_used_add.tsv';

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
        $user_used_add_log->printflush(join("\t", $time, $login, $ip, $succeeded), "\n");
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


sub notfound() {q{<!doctype html>
<html>
<head>
<meta charset=utf-8 />
<style type="text/css">
.message {
  font-size: 200%;
  margin: 20px 20px;
  color: #666;
}
.message strong {
  font-size: 250%;
  font-weight: bold;
  color: #333;
}
</style>
</head>
<body>
<p class="message">
<strong>404</strong> Not Found
</p>
</div>
</body>
</html>}}


sub base_top() {q{<!DOCTYPE html>
<html>
  <head>
    <meta charset="UTF-8">
    <link rel="stylesheet" href="/stylesheets/bootstrap.min.css">
    <link rel="stylesheet" href="/stylesheets/bootflat.min.css">
    <link rel="stylesheet" href="/stylesheets/isucon-bank.css">
    <title>isucon4</title>
  </head>
  <body>
    <div class="container">
      <h1 id="topbar">
        <a href="/"><img src="/images/isucon-bank.png" alt="いすこん銀行 オンラインバンキングサービス"></a>
      </h1>
}}

sub base_bottom() {q{</div>

  </body>
</html>
}}

sub content_index {
    my $session = shift;

    my @body = (q{<div id="be-careful-phising" class="panel panel-danger">
  <div class="panel-heading">
    <span class="hikaru-mozi">偽画面にご注意ください！</span>
  </div>
  <div class="panel-body">
    <p>偽のログイン画面を表示しお客様の情報を盗み取ろうとする犯罪が多発しています。</p>
    <p>ログイン直後にダウンロード中や、見知らぬウィンドウが開いた場合、<br>すでにウィルスに感染している場合がございます。即座に取引を中止してください。</p>
    <p>また、残高照会のみなど、必要のない場面で乱数表の入力を求められても、<br>絶対に入力しないでください。</p>
  </div>
</div>

<div class="page-header">
  <h1>ログイン</h1>
</div>
    });

    if ( $session && exists $session->{flash} ) {
        my $flash = delete $session->{flash};
        push @body, sprintf(q{  <div id="notice-message" class="alert alert-danger" role="alert">%s</div>}, $flashs->[$flash]);
    }

    push @body, q{


<div class="container">
  <form class="form-horizontal" role="form" action="/login" method="POST">
    <div class="form-group">
      <label for="input-username" class="col-sm-3 control-label">お客様ご契約ID</label>
      <div class="col-sm-9">
        <input id="input-username" type="text" class="form-control" placeholder="半角英数字" name="login">
      </div>
    </div>
    <div class="form-group">
      <label for="input-password" class="col-sm-3 control-label">パスワード</label>
      <div class="col-sm-9">
        <input type="password" class="form-control" id="input-password" name="password" placeholder="半角英数字・記号（２文字以上）">
      </div>
    </div>
    <div class="form-group">
      <div class="col-sm-offset-3 col-sm-9">
        <button type="submit" class="btn btn-primary btn-lg btn-block">ログイン</button>
      </div>
    </div>
  </form>
</div>};

    return @body;
}

sub mypage {
    my $env = shift;
    my $user = $env->{user};

    sprintf(q{<div class="alert alert-success" role="alert">
  ログインに成功しました。<br>
  未読のお知らせが０件、残っています。
</div>

<dl class="dl-horizontal">
  <dt>前回ログイン</dt>
  <dd id="last-logined-at">%s</dd>
  <dt>最終ログインIPアドレス</dt>
  <dd id="last-logined-ip">%s</dd>
</dl>

<div class="panel panel-default">
  <div class="panel-heading">
    お客様ご契約ID：%s 様の代表口座
  </div>
  <div class="panel-body">
    <div class="row">
      <div class="col-sm-4">
        普通預金<br>
        <small>東京支店　1111111111</small><br>
      </div>
      <div class="col-sm-4">
        <p id="zandaka" class="text-right">
          ―――円
        </p>
      </div>

      <div class="col-sm-4">
        <p>
          <a class="btn btn-success btn-block">入出金明細を表示</a>
          <a class="btn btn-default btn-block">振込・振替はこちらから</a>
        </p>
      </div>

      <div class="col-sm-12">
        <a class="btn btn-link btn-block">定期預金・住宅ローンのお申込みはこちら</a>
      </div>
    </div>
  </div>
</div>}, $user->{last_login1} ? strftime('%Y-%m-%d %H:%M:%S', localtime($user->{last_login1})) : '', $user->{last_ip1}, $user->{login});
}

sub set_flash {
    my $msg_id = shift;
    
    my $session = +{flash => $msg_id};
    my $sid = _generate_sid();
    $mysessionstore->{$sid} = $session;
    return ['302', [Location => "${uri_base}/", 'Set-Cookie' => "isu4_session=$sid; path=/; HttpOnly"], []];
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
    my $ip       = $env->{REMOTE_ADDR};

    if ( exists $banned_ips->{$ip} ) {
        add_log(time, $login, $ip, 0);
        return set_flash(1); # You're banned.
    }
    if ( exists $locked_users->{$login} ) {
        add_log(time, $login, $ip, 0);
        return set_flash(0); # This account is locked.
    }

    if ( $user && $user->{password} eq $password ) {
        add_log(time, $login, $ip, 1);

        my $session = +{login => $login};
        my $sid = _generate_sid();
        $mysessionstore->{$sid} = $session;
        return ['302', [Location => "${uri_base}/mypage", 'Set-Cookie' => "isu4_session=$sid; path=/; HttpOnly"], []];
    }

    add_log(time, $login, $ip, 0);
    return set_flash(2); # Wrong username or password
}


sub app {
    my $env = shift;
    my $res = _app($env);
    if ( $res->[0] == 404 ) {
        $res->[2] = [notfound()];
    }
    if ( exists $env->{user} ) {
        my $myheader = [@{$res->[1]}];
        push $myheader, 'Cache-Control', 'private';
        $res->[1] = $myheader;
    }
    return $res;
}

sub _app {
    my $env = shift;
    my $method    = $env->{REQUEST_METHOD};
    my $path_info = $env->{PATH_INFO};

    $path_info =~ s{\A/user}{};

    if ( $env->{'HTTP_X_FORWARDED_FOR'} ) {
        my ( $ip, ) = $env->{HTTP_X_FORWARDED_FOR} =~ /([^,\s]+)$/;
        $env->{REMOTE_ADDR} = $ip;
    }

    $uri_base = 'http://' . $env->{HTTP_HOST};

    my $sid = $env->{'psgix.nginx_request'}->variable('cookie_isu4_session');
    my $session = $sid ? $mysessionstore->{$sid} : undef;
 
    if ( $session && exists $session->{login} && exists $users->{$session->{login}} ) {
        $env->{user} = $users->{$session->{login}};
    }

    if ( $method eq 'GET' ) {
        if ( $path_info eq '/' ) {
            my @cookie_rm_header = $sid ? (
                'Set-Cookie' => "isu4_session=$sid; path=/; HttpOnly; expires=Fri, 31-Dec    -1999 23:59:59 GMT"
            ) : ();
            if ( $session && exists $session->{flash} ) {
                return ['200', [@$header, @cookie_rm_header], [
                    base_top(),
                    content_index($session),
                    base_bottom(),
                ]];
	    }
	    return ['200', [@$header, @cookie_rm_header], IO::File::WithPath->new('/home/isucon/webapp/public/index.html')];
        }
        elsif ( $path_info eq '/mypage' ) {
            return ['302', [Location => "${uri_base}/"], []] unless $env->{user};
            return ['200', $header, [
                base_top(),
                mypage($env),
                base_bottom(),
            ]];
        }
        elsif ( $path_info eq '/report' ) {
            return ['200', ['Content-Type' => 'application/json; charset=UTF-8'], [
                encode_json({
                    banned_ips => [keys $banned_ips],
                    locked_users => [keys $locked_users],
                })
            ]];
        }
    }
    elsif ( $method eq 'POST' ) {
        my $input = delete $env->{'psgi.input'};
        my $body = '';
        $input->read($body, $env->{CONTENT_LENGTH});
        $env->{param} = { map { split('=',$_,2) } split('&',$body)};
        for ( values $env->{param} ) {
            s/\+/ /g;
            $_ = uri_unescape($_);
        }

        if ( $path_info eq '/login' ) {
            return post_login($env);
        }
    }

    return ['404', $header, ['not found']];
}


\&app;

