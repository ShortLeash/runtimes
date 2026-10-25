<?php
// static-php-cli builds curl with c-ares whenever c-ares is in the build, and
// grpc and swoole bring it in. On macOS c-ares skips the per-domain resolvers
// in /etc/resolver, so curl couldn't resolve names the system can (a local
// .test domain, a VPN's internal names). Build curl with its threaded resolver,
// which asks the system's getaddrinfo instead. grpc and swoole keep c-ares.
if (patch_point() === 'before-library[curl]-build') {
    $cmake = builder()->getLib('curl')->getSourceDir() . '/CMakeLists.txt';
    $option = 'option(ENABLE_ARES "Enable c-ares support" OFF)';
    if (!str_contains(file_get_contents($cmake), $option)) {
        throw new \RuntimeException("curl's CMakeLists.txt no longer declares ENABLE_ARES as expected: update spc-patches/curl-system-resolver.php");
    }
    // -DENABLE_ARES=ON sets the cache entry; this overrides it for everything
    // after, the threaded resolver's default included.
    \SPC\store\FileSystem::replaceFileStr(
        $cmake,
        $option,
        $option . "\nset(ENABLE_ARES OFF CACHE BOOL \"Enable c-ares support\" FORCE)",
    );
}
