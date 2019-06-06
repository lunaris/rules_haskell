"""Action for creating packages and registering them with ghc-pkg"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load(":private/path_utils.bzl", "get_lib_name", "target_unique_name")
load(":private/pkg_id.bzl", "pkg_id")
load(":private/set.bzl", "set")
load(":providers.bzl", "get_extra_libs")

def _get_extra_libraries(hs, with_shared, cc_info):
    """Get directories and library names for extra library dependencies.

    Args:
      cc_info: Combined CcInfo provider of the package's dependencies.

    Returns:
      (dirs, libs):
      dirs: list: Library search directories for extra library dependencies.
      libs: list: Extra library dependencies.
    """

    # NOTE This is duplicated from path_utils.bzl link_libraries. This whole
    # function can go away once we track libraries outside of package
    # configuration files.
    dynamic = with_shared
    (static_libs, dynamic_libs) = get_extra_libs(hs, dynamic, cc_info)

    # This test is a hack. When a CC library has a Haskell library
    # as a dependency, we need to be careful to filter it out,
    # otherwise it will end up polluting the linker flags. GHC
    # already uses hs-libraries to link all Haskell libraries.
    #
    # TODO Get rid of this hack. See
    # https://github.com/tweag/rules_haskell/issues/873.
    cc_static_libs = depset(direct = [
        lib
        for lib in static_libs.to_list()
        if not get_lib_name(lib).startswith("HS")
    ])
    cc_dynamic_libs = depset(direct = [
        lib
        for lib in dynamic_libs.to_list()
        if not get_lib_name(lib).startswith("HS")
    ])
    cc_libs = cc_static_libs.to_list() + cc_dynamic_libs.to_list()

    lib_dirs = depset(direct = [
        lib.dirname
        for lib in cc_libs
    ])

    lib_names = [
        get_lib_name(lib)
        for lib in cc_libs
    ]

    return (lib_dirs.to_list(), lib_names)

def package(
        hs,
        dep_info,
        cc_info,
        with_shared,
        exposed_modules_file,
        other_modules,
        my_pkg_id):
    """Create GHC package using ghc-pkg.

    Args:
      hs: Haskell context.
      dep_info: Combined HaskellInfo of dependencies.
      cc_info: Combined CcInfo of dependencies.
      with_shared: Whether to link dynamic libraries.
      exposed_modules_file: File holding list of exposed modules.
      other_modules: List of hidden modules.
      my_pkg_id: Package id object for this package.

    Returns:
      (File, File): GHC package conf file, GHC package cache file
    """
    pkg_db_dir = pkg_id.to_string(my_pkg_id)
    conf_file = hs.actions.declare_file(
        paths.join(pkg_db_dir, "{0}.conf".format(pkg_db_dir)),
    )

    import_dir = paths.join(
        "${pkgroot}",
        paths.join(pkg_db_dir, "_iface"),
    )

    (extra_lib_dirs, extra_libs) = _get_extra_libraries(hs, with_shared, cc_info)

    # Create a file from which ghc-pkg will create the actual package
    # from. List of exposed modules generated below.
    metadata_file = hs.actions.declare_file(target_unique_name(hs, "metadata"))
    write_package_conf(hs, metadata_file, {
        "name": my_pkg_id.package_name,
        "version": my_pkg_id.version,
        "id": pkg_id.to_string(my_pkg_id),
        "key": pkg_id.to_string(my_pkg_id),
        "exposed": "True",
        "hidden-modules": other_modules,
        "import-dirs": [import_dir],
        "library-dirs": ["${pkgroot}"] + extra_lib_dirs,
        "dynamic-library-dirs": ["${pkgroot}"] + extra_lib_dirs,
        "hs-libraries": [pkg_id.library_name(hs, my_pkg_id)],
        "extra-libraries": extra_libs,
        "depends": hs.package_ids,
    })

    # Combine exposed modules and other metadata to form the package
    # configuration file.

    hs.actions.run_shell(
        inputs = [metadata_file, exposed_modules_file],
        outputs = [conf_file],
        command = """
            cat $1 > $3
            echo "exposed-modules: `cat $2`" >> $3
""",
        arguments = [
            metadata_file.path,
            exposed_modules_file.path,
            conf_file.path,
        ],
        use_default_shell_env = True,
    )

    cache_file = ghc_pkg_recache(hs, conf_file)

    return conf_file, cache_file

def write_package_conf(hs, conf_file, metadata):
    """Write GHC package configuration file.

    See https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/packages.html

    Args:
      hs: Haskell context.
      conf_file: The declared output file.
      metadata: Dictionary from package configuration fields to their values.
    """

    # Use an Args object to avoid building up large strings in Starlark.
    package_conf = hs.actions.args()
    package_conf.set_param_file_format("multiline")

    formatters = {
        "name": ("add", {}),
        "id": ("add", {}),
        "key": ("add", {}),
        "version": ("add", {}),
        "exposed": ("add", {}),
        "depends": ("add_joined", {"join_with": ", "}),
        "exposed-modules": ("add_joined", {"join_with": " "}),
        "hidden-modules": ("add_joined", {"join_with": " "}),
        "import-dirs": ("add_joined", {"join_with": " "}),
        "hs-libraries": ("add_joined", {"join_with": " "}),
        "extra-libraries": ("add_joined", {"join_with": " "}),
        "extra-ghci-libraries": ("add_joined", {"join_with": " "}),
        "library-dirs": ("add_joined", {"join_with": " "}),
        "dynamic-library-dirs": ("add_joined", {"join_with": " "}),
        "ld-options": ("add_joined", {"join_with": " ", "format_each": '"%s"'}),
    }

    for (k, v) in metadata.items():
        if not v:
            continue
        formatter = formatters.get(k)
        if not formatter:
            fail("Unknown package configuration field '{}'.".format(k))
        (method, kwargs) = formatter
        linefmt = "{}: %s".format(k)
        if method == "add":
            package_conf.add(v, format = linefmt, **kwargs)
        elif method == "add_joined":
            package_conf.add_joined(v, format_joined = linefmt, **kwargs)
        else:
            fail("Unknown Args method '{}'.".format(method))

    hs.actions.write(conf_file, package_conf)

def ghc_pkg_recache(hs, conf_file):
    """Run ghc-pkg recache on the given package configuration file.

    Note, this will generate the file package.cache in the same directory as
    conf_file. Calling this function on two different package configuration
    files in the same directory is an error as it will generate conflicting
    actions.

    Args:
      hs: Haskell context.
      conf_file: The package configuration file.

    Returns:
      File, the generate package cache file.

    """

    cache_file = hs.actions.declare_file("package.cache", sibling = conf_file)

    # Make the call to ghc-pkg and use the package configuration file
    hs.actions.run(
        inputs = depset(direct = [conf_file]),
        outputs = [cache_file],
        mnemonic = "HaskellRegisterPackage",
        progress_message = "HaskellRegisterPackage {}".format(conf_file.short_path),
        executable = hs.tools.ghc_pkg,
        # Registration of a new package consists in,
        #
        # 1. copying the registration file into the package db,
        # 2. performing some validation on the registration file content,
        # 3. recaching, i.e. regenerating the package db cache file.
        #
        # Normally, this is all done by `ghc-pkg register`. But in our
        # case, `ghc-pkg register` is painful, because the validation
        # it performs is slow, somewhat redundant but especially, too
        # strict (see e.g.
        # https://ghc.haskell.org/trac/ghc/ticket/15478). So we do (1)
        # and (3) manually, by copying then calling `ghc-pkg recache`
        # directly.
        #
        # The downside is that we do lose the few validations that
        # `ghc-pkg register` was doing that was useful. e.g. when
        # reexporting modules, validation checks that the source
        # module does exist.
        #
        # TODO Go back to using `ghc-pkg register`. Blocked by
        # https://ghc.haskell.org/trac/ghc/ticket/15478
        arguments = [
            "recache",
            "--package-db={0}".format(conf_file.dirname),
            "-v0",
            "--no-expand-pkgroot",
        ],
        # XXX: Seems required for this to work on Windows.
        use_default_shell_env = hs.toolchain.is_windows,
    )

    return cache_file
