<?php
// PHP 8.2's libbcmath is K&R-style C, which C23 rejects. Newer autoconf makes
// php-src's configure try -std=gnu23 first; use gnu17 instead. static-php-cli
// does the same after 2.8.5 (commit 970343b); drop this once a release has it.
if (patch_point() === 'before-php-configure' && builder()->getPHPVersionID() < 80300) {
    \SPC\store\FileSystem::replaceFileStr(
        SOURCE_PATH . '/php-src/configure',
        "for ac_arg in '' -std=gnu23",
        "for ac_arg in '' -std=gnu17",
    );
}
