package App::BlogAlba;

use strict;
use warnings;

use Cwd;
# TODO: maybe swap this out for templating stuff through dancer, would be cleaner.
use HTML::Template;
use Text::Markdown::Hoedown;

use POSIX qw/strftime/;
use Date::Parse qw/str2time/; #Required for converting the date field in posts to something strftime can work with
use Time::HiRes qw/gettimeofday tv_interval/;
use XML::RSS;
use Unicode::Normalize;

use Dancer2;

my $HOST = `hostname -s`; chomp $HOST;

my $basedir=$ENV{BASE}."/".$ENV{APP} || cwd();
config->{url} .= '/' unless config->{url} =~ /\/$/;

my ($page,@posts,@pages,%defparams);
my $nposts=0;my $npages=1;my $lastcache=0;

sub readpost {
	my $file = shift;my $psh = shift || 1;
	my $postb = ""; my $postmm = "";
	open POST, $file or warn "Couldn't open $file!" and return 0;
	my $status = 0;
	while (<POST>) {
		$postb .= $_ if $status==2;
		/^-{3,}$/ and not $status==2 and $status = $status==1? 2 : 1;
		$postmm .= $_ if $status==1;
	}
	close POST; undef $status;
	my %postm = %{YAML::Load($postmm)}; undef $postmm;
	$postm{filename} = $1 if $file =~ /(?:^|\/)([a-zA-Z0-9\-]*)\.md$/;
	$postm{body} = markdown(
		$postb,
		extensions => HOEDOWN_EXT_TABLES
			| HOEDOWN_EXT_FENCED_CODE
			| HOEDOWN_EXT_FOOTNOTES
			| HOEDOWN_EXT_AUTOLINK
			| HOEDOWN_EXT_STRIKETHROUGH
			| HOEDOWN_EXT_UNDERLINE
			| HOEDOWN_EXT_HIGHLIGHT
			| HOEDOWN_EXT_SUPERSCRIPT
			| HOEDOWN_EXT_NO_INTRA_EMPHASIS);
	$postm{mdsource} = $postb;
	undef $postb;
	if (defined $postm{date}) {
		$postm{slug} = slugify($postm{title}) unless $postm{slug}; #we allow custom slugs to be defined
		$postm{hastags} = 1 unless not defined $postm{tags};
		$postm{excerpt} = $1 if $postm{body} =~ /(<p>.*?<\/p>)/s;
		$postm{time} = str2time($postm{date});
		$postm{fancy} = timefmt($postm{time},'fancydate');
		$postm{datetime} = timefmt($postm{date},'datetime');
		$postm{permaurl} = config->{url}.config->{posturlprepend}.timefmt($postm{time},'permalink').$postm{slug};
	}
	push @posts,{%postm} if $psh==1; push @pages,{%postm} if $psh==2;return %postm;
}
sub slugify {
	my $t = shift;
	$t = lc NFKD($t); #Unicode::Normalize
	$t =~ tr/\000-\177//cd; #Strip non-ascii
	$t =~ s/[^\w\s-]//g; #Strip non-words
	chomp $t;
	$t =~ s/[-\s]+/-/g; #Prevent multiple hyphens or any spaces
	return $t;
}
sub timefmt {
	my ($epoch,$context)=@_;
	$epoch=str2time $epoch if $epoch !~ /^[0-9]{10}$/;
	my $dsuffix = 'th'; $dsuffix = 'st' if strftime("%d",localtime $epoch) =~ /1$/; $dsuffix = 'nd' if strftime("%d",localtime $epoch) =~ /2$/;
	return strftime "%A, %e$dsuffix %b. %Y", localtime $epoch if $context eq 'fancydate';
	return strftime "%Y-%m-%dT%H:%M%z",localtime $epoch if $context eq 'datetime';
	return strftime "%Y-%m",localtime $epoch if $context eq 'writepost';
	return strftime "%Y/%m/",localtime $epoch if $context eq 'permalink';
	return strftime $context, localtime $epoch if $context;
	return strftime config->{conf}->{date_format},localtime $epoch;
}
sub pagination_calc {
	my $rem=$nposts % config->{conf}->{per_page};
	$npages=($nposts-$rem)/config->{conf}->{per_page};
	$npages++ if $rem>0 or $npages<1;
}
sub get_index {
	my @iposts = @_;
	$page->param(pagetitle => config->{name}, INDEX => 1, POSTS => [@iposts]);
	return $page->output;
}
sub paginate {
	my $pagenum = shift; my $offset = ($pagenum-1)*config->{conf}->{per_page};
	my $offset_to = $offset+(config->{conf}->{per_page}-1); $offset_to = $#posts if $offset_to > $#posts;
	$page->param(PAGINATED => 1, prevlink => ($pagenum>1? 1 : 0), prevpage => $pagenum-1, nextlink => ($pagenum<$npages? 1 : 0), nextpage => $pagenum+1);
	return get_index @posts[$offset..(($offset+config->{conf}->{per_page})>$#posts? $#posts : ($offset+(config->{conf}->{per_page}-1)))];
}
sub page_init {
	$page = HTML::Template->new(filename => "$basedir/layout/base.html",die_on_bad_params => 0,utf8 => 1,global_vars => 1);
	$page->param(%defparams);
}
sub get_post {
	my ($y,$m,$slug) = @_;
	for my $r (@posts) {
		my %post = %$r;
		next unless $post{slug} eq $slug and timefmt($post{time},'writepost') eq "$y-$m";
		$page->param(pagetitle => $post{title}." - ".config->{name},%post);
		return 1;
	}
	return undef;
}
sub get_page {
	my $pname = shift;
	for my $r (@pages) {
		my %cpage = %$r;
		next unless $cpage{filename} eq $pname;
		$page->param(pagetitle => $cpage{title}" - ".config->{name},%cpage);
		return 1;
	}
	return undef;
}
sub generate_feed {
	return unless config->{conf}->{rss_publish};
	my $feed = new XML::RSS(version => '2.0');
	$feed->channel (
		title			=> config->{name},
		link			=> config->{url},
		description		=> config->{tagline},
		dc	=> {
			creator		=> config->{author},
			language	=> config->{locale},
		},
		syn	=> {
			updatePeriod	=> "daily",
			updateFrequency	=> "1",
			updateBase		=> "1970-01-01T00:00+00:00",
		},
	);
	$feed->add_item (
		title			=> $_->{title},
		link			=> $_->{permaurl},
		description		=> (config->{conf}->{rss_excerpt}? $_->{excerpt} : $_->{body}),
		dc	=> { creator => config->{author}, },
	) for @posts[0 .. ($#posts > (config->{conf}->{recent_posts}-1)? (config->{conf}->{recent_posts}-1) : $#posts)];
	$feed->save("$basedir/public/feed-rss2.xml");
}
sub do_cache {
	return if $lastcache > (time - 3600);
	$lastcache = time;my $st=[gettimeofday];
	undef @posts;undef @pages;$nposts=0;
	opendir POSTS, "$basedir/posts/" or die "Couldn't open posts directory $basedir/posts/";
	while(readdir POSTS) {
		next unless /\.md$/;
		warn "Error reading post $_\n" and next unless readpost("$basedir/posts/$_",1);
		$nposts++;
	}
	closedir POSTS;
	@posts = map {$_->[1]} sort {$b->[0] <=> $a->[0]} map {[$_->{time},$_]} @posts;

	opendir PAGES, "$basedir/pages/" or die "Couldn't open pages directory $basedir/pages/";
	while(readdir PAGES) {
		next unless /\.md$/;
		warn "Error reading page $_\n" and next unless readpost("$basedir/pages/$_",2);
	}
	closedir PAGES;

	my @nav;
	push @nav, {navname => $_->{title}, navurl => config->{url}.$_->{filename},} for @pages;
	push @nav, {navname => $_, navurl => config->{links}->{$_},} for sort { $b cmp $a } keys config->{links};
	generate_feed;
	%defparams = (
		INDEX => 0, NAV => [@nav], url => config->{url}, recent => [@posts[0 .. ($#posts > (config->{conf}->{recent_posts}-1)? (config->{conf}->{recent_posts}-1) : $#posts)]],
		gentime => timefmt($lastcache, '%H:%M %e/%-m/%y %Z'), genworktime => sprintf("%.2f ms", tv_interval($st)*100), host => $HOST, rss_enabled => config->{rss_publish},
		about => config->{about}, author => config->{author}, name => config->{name}, tagline => config->{tagline}, keywords => config->{keywords},
		robots => config->{conf}->{indexable}? '<meta name="ROBOTS" content="INDEX, FOLLOW" />' : '<meta name="ROBOTS" content="NOINDEX, NOFOLLOW" />',
	);
	pagination_calc;
}

hook 'before' => sub {
	do_cache;
	page_init;
};

get '/' => sub {
	return get_index @posts if $npages==1;
	return paginate 1;
};
get '/page/:id' => sub {
	pass unless params->{id} =~ /^[0-9]+$/ and params->{id} <= $npages;
	return redirect '/' unless $npages > 1 and params->{id} > 1;
	return paginate params->{id};
};
get '/wrote/:yyyy/:mm/:slug' => sub {
	pass unless params->{yyyy} =~ /^[0-9]{4}$/ and params->{mm} =~ /^(?:0[1-9]|1[0-2])$/ and params->{slug} =~ /^[a-z0-9\-]+(?:\.md)?$/i;
	if (params->{slug} =~ s/\.md$//) { $page->param(SOURCEVIEW => 1); header('Content-Type' => 'text/plain'); }
	$page->param(ISPOST => 1);
	get_post params->{yyyy}, params->{mm}, params->{slug} or pass;
	return $page->output;
};
get '/:extpage' => sub {
	pass unless params->{extpage} =~ /^[a-z0-9\-]+(?:\.md)?$/i;
	if (params->{extpage} =~ s/\.md$//) { $page->param(SOURCEVIEW => 1); header('Content-Type' => 'text/plain'); }
	$page->param(ISPOST => 0);
	get_page params->{extpage} or pass;
	return $page->output;
};
# 404
any qr/.*/ => sub {
	return redirect '/' if request->path =~ /index(?:\.(?:html?|pl)?)?$/;
	return send_error('The page you seek cannot be found.', 404);
};

1;
__END__
