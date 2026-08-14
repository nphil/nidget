#!/usr/bin/perl
#
# render-app-icons.pl — draws Nidget's app icons straight to PNG.
#
# The icon is the app's own ProgressRing with a stylized N inside it: a radial background
# anchored at the bottom-right corner, a 120pt ring stroke sweeping 283 degrees clockwise from
# twelve o'clock with round caps, a dot on the end cap, and a three-stroke N centred in the ring's
# counter. Every number below was measured off the 1.0.15 icon, so the ring lands exactly where it
# always has.
#
# Why a renderer and not a checked-in binary: there are 43 icons (the primary in its light, dark
# and tinted appearances, plus one per theme in ThemeCatalog), and the theme ones are derived from
# the Swift palettes. Hand-editing 43 PNGs whenever a palette moves is not a thing anyone will do.
#
# Geometry is evaluated once and reused for every icon, so only the colors differ per file.
#
#   perl scripts/render-app-icons.pl                     # all icons, into the asset catalog
#   perl scripts/render-app-icons.pl --out /tmp/preview   # somewhere else, to look first
#   perl scripts/render-app-icons.pl --only AppIcon       # one icon set
#   perl scripts/render-app-icons.pl --size 180           # smaller, for a quick look
#
use strict;
use warnings;
use Compress::Zlib qw(compress crc32);
use File::Path     qw(make_path);
use File::Basename qw(dirname);

# ---------------------------------------------------------------------------- geometry constants
#
# All in 1024-space; --size scales the whole drawing.

use constant {
    CANVAS      => 1024,
    RING_CX     => 512,
    RING_CY     => 512,
    RING_R      => 318,     # mid-radius of the stroke
    RING_HALF   => 60,      # half of the 120pt stroke
    ARC_SWEEP   => 283,     # degrees clockwise from twelve o'clock
    DOT_R       => 26,      # the marker riding the end cap
    N_HEIGHT    => 296,     # cap height of the monogram
    N_WIDTH     => 190,     # distance between the two stem centres
    N_HALF      => 37,      # half of the monogram's 74pt stroke
};

# ------------------------------------------------------------------------------------- icon specs

# Colors are hex strings. `bg` is a list of [position, color] stops for the radial gradient, from
# the bright bottom-right corner out to the far top-left. `track` is the alpha of the dim ring
# behind the gap; it picks up the arc's own color at that angle, exactly like ProgressRing does.
sub primary_specs {
    (
        {   # Light appearance, and the icon's identity: navy into indigo, mint into cyan.
            set => 'AppIcon', file => 'AppIcon',
            bg  => [[0, '4434A6'], [0.704, '27205E'], [1, '0F1023']],
            arc => ['3EE6A0', '6DD5FE'],
            track => 0.15, dot => 'F0FAFF', mono => 'F2F7FF',
        },
        {   # Dark appearance: the same mark on a deeper ground so it settles into a dark
            # wallpaper instead of glowing off it. The ring brightens a touch to compensate.
            set => 'AppIcon', file => 'AppIcon-Dark',
            bg  => [[0, '2A2170'], [0.704, '15113A'], [1, '07070F']],
            arc => ['4BEDA9', '78DDFF'],
            track => 0.13, dot => 'F5FBFF', mono => 'F7FAFF',
        },
        {   # Tinted appearance: iOS recolors this one itself, so it ships greyscale. Luminance is
            # what survives, so the ring and the N keep their separation by brightness alone. The
            # cap marker inverts here — a white dot on a white cap would simply disappear.
            set => 'AppIcon', file => 'AppIcon-Tinted',
            bg  => [[0, '3C3C3C'], [0.704, '1C1C1C'], [1, '0A0A0A']],
            arc => ['D8D8D8', 'FFFFFF'],
            track => 0.15, dot => '1C1C1C', mono => 'FFFFFF',
        },
    );
}

# --------------------------------------------------------------------------- theme-derived icons
#
# One alternate icon per theme in ThemeCatalog, built from that theme's own palette so the home
# screen matches whatever is on screen. The Swift catalog stays the single source of truth: these
# are parsed out of it rather than duplicated here.

sub parse_theme_catalog {
    my ($root) = @_;
    my @themes;

    for my $file ("$root/Nidget/DesignSystem/ThemeCatalog+Light.swift",
                  "$root/Nidget/DesignSystem/ThemeCatalog+Dark.swift") {
        open my $fh, '<', $file or die "$file: $!";
        my $src = do { local $/; <$fh> };
        close $fh;

        # Split on the `static let <name> = Theme(` declarations, then read each block's fields.
        my @blocks = split /(?=^\s*static let \w+ = Theme\()/m, $src;
        for my $b (@blocks) {
            next unless $b =~ /id:\s*"([^"]+)"/;
            my $id = $1;
            my ($name) = $b =~ /name:\s*"([^"]+)"/;
            my ($mode) = $b =~ /mode:\s*\.(\w+)/;

            # Every backdrop style names its dominant color first, whether that is .solid's only
            # color, a gradient's top stop, a mesh's first control point, .aurora's base or
            # .horizon's top — so the first color after `backdrop:` is the one to build on.
            my ($base) = $b =~ /backdrop:.*?Color\(red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+)\)/s
                ? [$1, $2, $3] : undef;

            my %c;
            for my $key (qw(accent accentSecondary textPrimary)) {
                $b =~ /^\s+\Q$key\E:\s*Color\(red:\s*([\d.]+),\s*green:\s*([\d.]+),\s*blue:\s*([\d.]+)\)/m
                    or die "theme $id: could not read $key\n";
                $c{$key} = [$1, $2, $3];
            }
            die "theme $id: could not read backdrop\n" unless $base;

            push @themes, {
                id => $id, name => $name, mode => $mode, base => $base,
                accent => $c{accent}, accentSecondary => $c{accentSecondary},
                text => $c{textPrimary},
            };
        }
    }
    return @themes;
}

# --- small color helpers, all on 0..1 triples

sub mix3 { my ($a, $b, $t) = @_; return [map { lerp($a->[$_], $b->[$_], $t) } 0 .. 2] }
sub lum3 { my ($c) = @_; return 0.2126 * $c->[0] + 0.7152 * $c->[1] + 0.0722 * $c->[2] }

# Relative luminance the way WCAG defines it, on linearized channels, and the contrast ratio of a
# color against white. Needed because plain channel-weighted brightness badly misjudges how well
# white reads on a saturated cyan or a mid grey.
sub rel_lum {
    my ($c) = @_;
    my @l = map { $_ <= 0.03928 ? $_ / 12.92 : ((($_ + 0.055) / 1.055) ** 2.4) } @$c;
    return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2];
}
sub contrast_with_white { my ($c) = @_; return 1.05 / (rel_lum($c) + 0.05) }
sub hex3 { my ($c) = @_; return sprintf '%02X%02X%02X',
               map { my $v = int($_ * 255 + 0.5); $v < 0 ? 0 : ($v > 255 ? 255 : $v) } @$c }

my $BLACK = [0, 0, 0];
my $WHITE = [1, 1, 1];

# Push a color until it is at least (or at most) the target luminance, without changing its hue.
sub at_least_light { my ($c, $t) = @_; my $l = lum3($c);
    return $l >= $t ? $c : mix3($c, $WHITE, ($t - $l) / (1 - $l + 1e-6)) }
sub at_most_light  { my ($c, $t) = @_; my $l = lum3($c);
    return $l <= $t ? $c : mix3($c, $BLACK, ($l - $t) / ($l + 1e-6)) }

sub theme_spec {
    my ($theme) = @_;
    my $dark = $theme->{mode} eq 'dark';

    # The background keeps the original icon's move: the bottom-right corner carries the color and
    # it falls away towards the top-left. Dark themes lift that corner with accentSecondary the way
    # the navy original lifts into indigo; light themes wash it with accent and fade towards white.
    my ($corner, $far);
    if ($dark) {
        $corner = at_most_light(mix3($theme->{base}, $theme->{accentSecondary}, 0.40), 0.24);
        $far    = mix3($theme->{base}, $BLACK, 0.45);
    } else {
        $corner = at_most_light(mix3($theme->{base}, $theme->{accent}, 0.30), 0.80);
        $far    = mix3($theme->{base}, $WHITE, 0.50);
    }

    # The original's midpoint sits above a straight ramp — measured at 55% of the way across at
    # t=0.704 — which is what gives the background its soft falloff. Reproduce it for every theme.
    my $mid = mix3($corner, $far, 0.55);

    # The sweep runs accent into accentSecondary exactly like ProgressRing, then gets forced into
    # a luminance range that separates it from its own background. Some palettes are pale enough
    # that the untouched accent would vanish.
    my ($lo, $hi) = ($theme->{accent}, $theme->{accentSecondary});
    if ($dark) { $lo = at_least_light($lo, 0.45); $hi = at_least_light($hi, 0.45) }
    else       { $lo = at_most_light($lo, 0.50);  $hi = at_most_light($hi, 0.50)  }

    # The white marker on the sweep's end cap is part of the mark, so it stays white everywhere it
    # can. The original's own cap is a light cyan that white clears by only 1.67:1, so that ratio is
    # the bar: anything a theme hands back that still meets it keeps the white dot, and only a cap
    # too pale for even that (a near-white accentSecondary) punches through dark instead.
    my $dot = contrast_with_white($hi) >= 1.6 ? mix3($WHITE, $theme->{accent}, 0.06)
                                              : mix3($hi, $BLACK, 0.74);

    # textPrimary is built to carry body copy on a full screen, which is a gentler job than holding
    # a monogram against a saturated ring. Warm palettes hand back an N that sinks into the sweep,
    # so give it a floor.
    my $mono = $dark ? at_least_light($theme->{text}, 0.74)
                     : at_most_light($theme->{text}, 0.22);

    (my $slug = $theme->{id}) =~ s/\./-/g;

    return {
        set   => "ThemeIcon-$slug",
        file  => "ThemeIcon-$slug",
        theme => $theme->{id},
        bg    => [[0, hex3($corner)], [0.704, hex3($mid)], [1, hex3($far)]],
        arc   => [hex3($lo), hex3($hi)],
        track => $dark ? 0.15 : 0.20,
        dot   => hex3($dot),
        mono  => hex3($mono),
    };
}

# ------------------------------------------------------------------------------------- color math

sub hex_rgb {
    my ($hex) = @_;
    $hex =~ s/^#//;
    die "bad color '$hex'\n" unless $hex =~ /^[0-9a-fA-F]{6}$/;
    return map { hex($_) } ($hex =~ /(..)(..)(..)/);
}

sub lerp { my ($a, $b, $t) = @_; return $a + ($b - $a) * $t }

# 1024-entry lookup over the background gradient, so the fill is a table read per pixel.
sub gradient_lut {
    my ($stops, $steps) = @_;
    my @stops = map { [$_->[0], hex_rgb($_->[1])] } @$stops;
    my @lut;
    for my $i (0 .. $steps - 1) {
        my $t = $steps > 1 ? $i / ($steps - 1) : 0;
        my $k = 0;
        $k++ while $k < $#stops - 1 && $t > $stops[$k + 1][0];
        my ($lo, $hi) = @stops[$k, $k + 1];
        my $span = $hi->[0] - $lo->[0];
        my $f    = $span > 0 ? ($t - $lo->[0]) / $span : 0;
        $f = 0 if $f < 0; $f = 1 if $f > 1;
        $lut[$i] = pack 'C3', map { int(lerp($lo->[$_ + 1], $hi->[$_ + 1], $f) + 0.5) } 0 .. 2;
    }
    return \@lut;
}

# ------------------------------------------------------------------------------ signed distances

sub dist_to_segment {
    my ($px, $py, $x1, $y1, $x2, $y2) = @_;
    my ($dx, $dy) = ($x2 - $x1, $y2 - $y1);
    my $len2 = $dx * $dx + $dy * $dy;
    my $t = $len2 > 0 ? (($px - $x1) * $dx + ($py - $y1) * $dy) / $len2 : 0;
    $t = 0 if $t < 0; $t = 1 if $t > 1;
    my ($qx, $qy) = ($x1 + $t * $dx, $y1 + $t * $dy);
    return sqrt(($px - $qx) ** 2 + ($py - $qy) ** 2);
}

# One pixel of analytic antialiasing off a signed distance: -0.5 inside is solid, +0.5 outside is
# clear. Cheaper and cleaner on curves than supersampling, which matters at 43 icons.
sub coverage {
    my ($d) = @_;
    my $c = 0.5 - $d;
    return $c <= 0 ? 0 : ($c >= 1 ? 1 : $c);
}

# ---------------------------------------------------------------------------------- geometry pass
#
# Runs once. Produces:
#   bg_rows — per row, the gradient LUT index of every pixel (identical for all icons)
#   marks   — the sparse list of pixels any shape actually touches, with their coverages
#
# Everything the icons share lives here; a per-icon render is then a table lookup plus a patch
# over roughly a third of the canvas.

sub build_geometry {
    my ($size, $lut_steps) = @_;
    my $s = $size / CANVAS;                      # scale factor into pixel space

    my ($cx, $cy) = (RING_CX * $s, RING_CY * $s);
    my $ring_r    = RING_R * $s;
    my $ring_half = RING_HALF * $s;
    my $dot_r     = DOT_R * $s;
    my $n_half    = N_HALF * $s;

    # Cap centres: one at twelve o'clock, one where the sweep ends.
    my $rad  = ARC_SWEEP * atan2(1, 1) * 4 / 180;
    my @cap0 = ($cx, $cy - $ring_r);
    my @cap1 = ($cx + $ring_r * sin($rad), $cy - $ring_r * cos($rad));

    # The monogram: left stem up, diagonal down across the counter, right stem up.
    my $half_w = N_WIDTH * $s / 2;
    my $half_h = N_HEIGHT * $s / 2;
    my ($lx, $rx) = ($cx - $half_w, $cx + $half_w);
    my ($ty, $by) = ($cy - $half_h, $cy + $half_h);
    my @strokes = (
        [$lx, $ty, $lx, $by],    # left stem
        [$lx, $ty, $rx, $by],    # diagonal
        [$rx, $ty, $rx, $by],    # right stem
    );

    # Background gradient runs from the bottom-right corner outwards.
    my ($gx, $gy) = ($size, $size);
    my $gmax = sqrt($gx * $gx + $gy * $gy);

    my $deg = 180 / (atan2(1, 1) * 4);
    my (@bg_rows, @marks);

    for my $y (0 .. $size - 1) {
        my $py = $y + 0.5;
        my @row;
        for my $x (0 .. $size - 1) {
            my $px = $x + 0.5;

            my $gd = sqrt(($gx - $px) ** 2 + ($gy - $py) ** 2) / $gmax;
            my $gi = int($gd * ($lut_steps - 1) + 0.5);
            $gi = 0 if $gi < 0; $gi = $lut_steps - 1 if $gi > $lut_steps - 1;
            push @row, $gi;

            my ($dx, $dy) = ($px - $cx, $py - $cy);
            my $r = sqrt($dx * $dx + $dy * $dy);

            # The full-circle track sitting behind the sweep.
            my $band  = abs($r - $ring_r) - $ring_half;
            my $track = coverage($band);

            # The sweep itself: inside the angular range it is the band; outside it, the round
            # cap nearest the pixel.
            my ($arc, $arc_t) = (0, 0);
            if ($track > 0 || $band < 1) {
                my $theta = atan2($dx, -$dy) * $deg;
                $theta += 360 if $theta < 0;
                if ($theta <= ARC_SWEEP) {
                    $arc   = $track;
                    $arc_t = $theta / ARC_SWEEP;
                } else {
                    my $d0 = sqrt(($px - $cap0[0]) ** 2 + ($py - $cap0[1]) ** 2) - $ring_half;
                    my $d1 = sqrt(($px - $cap1[0]) ** 2 + ($py - $cap1[1]) ** 2) - $ring_half;
                    if ($d0 <= $d1) { $arc = coverage($d0); $arc_t = 0 }
                    else            { $arc = coverage($d1); $arc_t = 1 }
                }
            }

            my $dot = coverage(sqrt(($px - $cap1[0]) ** 2 + ($py - $cap1[1]) ** 2) - $dot_r);

            my $mono = 0;
            if ($r < $ring_r - $ring_half) {           # only ever inside the counter
                my $best;
                for my $sg (@strokes) {
                    my $d = dist_to_segment($px, $py, @$sg);
                    $best = $d if !defined $best || $d < $best;
                }
                $mono = coverage($best - $n_half);
            }

            push @marks, [$y * $size + $x, $track, $arc, $arc_t, $dot, $mono]
                if $track > 0 || $arc > 0 || $dot > 0 || $mono > 0;
        }
        push @bg_rows, \@row;
    }

    return { bg_rows => \@bg_rows, marks => \@marks, size => $size };
}

# ------------------------------------------------------------------------------------ composition

sub over {   # src over dst, straight alpha
    my ($sr, $sg, $sb, $a, $dr, $dg, $db) = @_;
    return (lerp($dr, $sr, $a), lerp($dg, $sg, $a), lerp($db, $sb, $a));
}

sub render_icon {
    my ($geo, $spec, $lut_steps) = @_;
    my $size = $geo->{size};
    my $lut  = gradient_lut($spec->{bg}, $lut_steps);

    # Background first: one table read per pixel, assembled a row at a time.
    my @rows = map { join '', @{$lut}[@$_] } @{ $geo->{bg_rows} };

    my @arc_lo  = hex_rgb($spec->{arc}[0]);
    my @arc_hi  = hex_rgb($spec->{arc}[1]);
    my @dot     = hex_rgb($spec->{dot});
    my @mono    = hex_rgb($spec->{mono});
    my $track_a = $spec->{track};

    for my $m (@{ $geo->{marks} }) {
        my ($idx, $track, $arc, $arc_t, $dot_c, $mono_c) = @$m;
        my $y   = int($idx / $size);
        my $x   = $idx % $size;
        my $off = $x * 3;

        my ($r, $g, $b) = unpack 'C3', substr($rows[$y], $off, 3);

        # The sweep's color at this angle, which the track borrows at low alpha.
        my @c = map { lerp($arc_lo[$_], $arc_hi[$_], $arc_t) } 0 .. 2;

        ($r, $g, $b) = over(@c, $track * $track_a, $r, $g, $b) if $track > 0;
        ($r, $g, $b) = over(@c, $arc, $r, $g, $b)              if $arc > 0;
        ($r, $g, $b) = over(@dot, $dot_c, $r, $g, $b)          if $dot_c > 0;
        ($r, $g, $b) = over(@mono, $mono_c, $r, $g, $b)        if $mono_c > 0;

        substr $rows[$y], $off, 3,
            pack 'C3', map { my $v = int($_ + 0.5); $v < 0 ? 0 : ($v > 255 ? 255 : $v) } $r, $g, $b;
    }

    return \@rows;
}

# --------------------------------------------------------------------------------- PNG encoding
#
# No alpha channel: iOS app icons must be fully opaque, so this writes truecolor (type 2).

sub png_chunk {
    my ($type, $body) = @_;
    return pack('N', length $body) . $type . $body . pack('N', crc32($type . $body));
}

# Per row, try each cheap filter and keep whichever leaves the smallest residual. Gradients this
# smooth shrink by roughly 4x versus writing them unfiltered.
sub filter_rows {
    my ($rows) = @_;
    my $stride = length $rows->[0];
    my $out    = '';
    my @prev   = (0) x $stride;

    for my $row (@$rows) {
        my @cur  = unpack 'C*', $row;
        my @best;
        my $best_score;

        for my $ft (0 .. 2) {
            my @f;
            for my $i (0 .. $stride - 1) {
                my $pred = $ft == 0 ? 0
                         : $ft == 1 ? ($i >= 3 ? $cur[$i - 3] : 0)
                         :            $prev[$i];
                $f[$i] = ($cur[$i] - $pred) & 255;
            }
            my $score = 0;
            $score += $_ > 127 ? 256 - $_ : $_ for @f;
            if (!defined $best_score || $score < $best_score) {
                $best_score = $score;
                @best       = ($ft, \@f);
            }
        }
        $out .= chr($best[0]) . pack('C*', @{ $best[1] });
        @prev = @cur;
    }
    return $out;
}

sub write_png {
    my ($path, $rows) = @_;
    my $size = scalar @$rows;

    my $png = "\x89PNG\r\n\x1a\n";
    $png .= png_chunk('IHDR', pack('N N C C C C C', $size, $size, 8, 2, 0, 0, 0));
    $png .= png_chunk('IDAT', compress(filter_rows($rows), 9));
    $png .= png_chunk('IEND', '');

    make_path(dirname $path) unless -d dirname $path;
    open my $fh, '>:raw', $path or die "$path: $!";
    print $fh $png;
    close $fh;
    return length $png;
}

# ------------------------------------------------------------------------------------------- main

sub write_contents_json {
    my ($dir, $specs) = @_;

    # The primary set carries all three iOS appearances in one .appiconset; the theme sets are
    # plain single-image alternates.
    my @entries;
    for my $s (@$specs) {
        my @lines = ('    {');
        if ($s->{appearance}) {
            push @lines,
                '      "appearances" : [',
                '        {',
                '          "appearance" : "luminosity",',
                '          "value" : "' . $s->{appearance} . '"',
                '        }',
                '      ],';
        }
        push @lines,
            '      "filename" : "' . $s->{file} . '.png",',
            '      "idiom" : "universal",',
            '      "platform" : "ios",',
            '      "size" : "1024x1024"',
            '    }';
        push @entries, join "\n", @lines;
    }

    my $json = join "\n",
        '{',
        '  "images" : [',
        join(",\n", @entries),
        '  ],',
        '  "info" : {',
        '    "author" : "xcode",',
        '    "version" : 1',
        '  }',
        "}\n";

    make_path($dir) unless -d $dir;
    open my $fh, '>', "$dir/Contents.json" or die "$dir/Contents.json: $!";
    print $fh $json;
    close $fh;
}

sub main {
    my %opt = (out => undef, size => CANVAS, only => undef);
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a eq '--out')  { $opt{out}  = shift @ARGV }
        elsif ($a eq '--size') { $opt{size} = shift @ARGV }
        elsif ($a eq '--only') { $opt{only} = shift @ARGV }
        else { die "unknown option '$a'\n" }
    }

    my $root = dirname(dirname(__FILE__));
    my $out  = $opt{out} // "$root/Nidget/Resources/Assets.xcassets";

    my @themes = parse_theme_catalog($root);
    my @specs  = (primary_specs(), map { theme_spec($_) } @themes);
    printf "%d themes in the catalog, %d icons to draw\n", scalar @themes, scalar @specs;

    @specs = grep { $_->{set} eq $opt{only} } @specs if defined $opt{only};
    die "no icon set matched --only $opt{only}\n" unless @specs;

    # iOS reads the appearance off Contents.json, not the filename.
    my %appearance = ('AppIcon-Dark' => 'dark', 'AppIcon-Tinted' => 'tinted');
    $_->{appearance} = $appearance{ $_->{file} } for @specs;

    my $lut_steps = 1024;
    print "geometry pass at $opt{size}px...\n";
    my $geo = build_geometry($opt{size}, $lut_steps);
    printf "  %d pixels carry a shape\n", scalar @{ $geo->{marks} };

    my ($count, $total) = (0, 0);
    my %by_set;
    push @{ $by_set{ $_->{set} } }, $_ for @specs;

    for my $set (sort keys %by_set) {
        my $dir = "$out/$set.appiconset";
        write_contents_json($dir, $by_set{$set});
        for my $spec (@{ $by_set{$set} }) {
            my $bytes = write_png("$dir/$spec->{file}.png", render_icon($geo, $spec, $lut_steps));
            $count++;
            $total += $bytes;
        }
    }
    printf "wrote %d PNGs, %.1f MB total\n", $count, $total / 1024 / 1024;
}

main();
