define wordpress::instance::app (
  $install_dir,
  $install_url,
  $version,
  $db_name,
  $db_host,
  $db_user,
  $db_password,
  $wp_owner,
  $wp_group,
  $wp_lang,
  $wp_config_content,
  $wp_plugin_dir,
  $wp_additional_config,
  $wp_table_prefix,
  $wp_proxy_host,
  $wp_proxy_port,
  $wp_multisite,
  $wp_site_domain,
  $wp_serveraliases,
  $wp_debug,
  $wp_debug_log,
  $wp_debug_display,
  $wp_redirect_target = "www.${wp_site_domain}",
) {
  validate_string($install_dir,$install_url,$version,$db_name,$db_host,$db_user,$db_password,$wp_owner,$wp_group, $wp_lang, $wp_plugin_dir,$wp_additional_config,$wp_table_prefix,$wp_proxy_host,$wp_proxy_port,$wp_site_domain)
  validate_bool($wp_multisite, $wp_debug, $wp_debug_log, $wp_debug_display)
  validate_absolute_path($install_dir)

  if $wp_config_content and ($wp_lang or $wp_debug or $wp_debug_log or $wp_debug_display or $wp_proxy_host or $wp_proxy_port or $wp_multisite or $wp_site_domain) {
    warning('When $wp_config_content is set, the following parameters are ignored: $wp_table_prefix, $wp_lang, $wp_debug, $wp_debug_log, $wp_debug_display, $wp_plugin_dir, $wp_proxy_host, $wp_proxy_port, $wp_multisite, $wp_site_domain, $wp_additional_config')
  }

  if $wp_multisite and ! $wp_site_domain {
    fail('wordpress class requires `wp_site_domain` parameter when `wp_multisite` is true')
  }

  if $wp_debug_log and ! $wp_debug {
    fail('wordpress class requires `wp_debug` parameter to be true, when `wp_debug_log` is true')
  }

  if $wp_debug_display and ! $wp_debug {
    fail('wordpress class requires `wp_debug` parameter to be true, when `wp_debug_display` is true')
  }

  ## Building the Apache vhost and modules required for wordpress
  class { 'apache':
	default_vhost => false,
	mpm_module => 'prefork',
  } 

  apache::vhost { $wp_site_domain:
	port          => '80',
	docroot       => $install_dir,
	docroot_owner => $wp_owner,
	docroot_group => $wp_group,
	php_values    => { upload_max_filesize => '20M' },
	override      => [ 'FileInfo' ],
	rewrites => [ { rewrite_cond => ["%{HTTP_HOST} !^${wp_redirect_target}$ [NC]"],	rewrite_rule => ["^(.*) http://${wp_redirect_target}/$1 [R]"] } ],
	serveraliases => $wp_serveraliases ? {
				''		=> '',
				default		=> $wp_serveraliases,
	},
  }

  class { 'php':
        dev => false,
        fpm => false,
        extensions => { memcached => { settings => { "session.save_handler" => memcache, "session.save_path" => "tcp://localhost:11211" } }, curl => {}, tidy => {},};
   }

  class { 'apache::mod::php': }
  class { 'apache::mod::rewrite': }
  class { 'apache::mod::headers': }
  class { 'apache::mod::expires': }

  ## Resource defaults
  File {
    owner  => $wp_owner,
    group  => $wp_group,
    mode   => '0644',
  }
  Exec {
    path      => ['/bin','/sbin','/usr/bin','/usr/sbin'],
    cwd       => $install_dir,
    logoutput => 'on_failure',
  }

  ## Installation directory
  if ! defined(File[$install_dir]) {
    file { $install_dir:
      ensure  => directory,
      recurse => true,
    }
  } else {
    notice("Warning: cannot manage the permissions of ${install_dir}, as another resource (perhaps apache::vhost?) is managing it.")
  }
  
  ## tar.gz. file name lang-aware
  if $wp_lang {
    $install_file_name = "wordpress-${version}-${wp_lang}.tar.gz"
  } else {
    $install_file_name = "wordpress-${version}.tar.gz"
  }

  ## Download and extract
  exec { "Download wordpress ${install_url}/wordpress-${version}.tar.gz to ${install_dir}":
    command => "wget ${install_url}/${install_file_name}",
    creates => "${install_dir}/${install_file_name}",
    require => File[$install_dir],
    user    => $wp_owner,
    group   => $wp_group,
  }
  -> exec { "Extract wordpress ${install_dir}":
    command => "tar zxvf ./${install_file_name} --strip-components=1",
    creates => "${install_dir}/index.php",
    user    => $wp_owner,
    group   => $wp_group,
  }
  ~> exec { "Change ownership ${install_dir}":
    command     => "chown -R ${wp_owner}:${wp_group} ${install_dir}",
    refreshonly => true,
    user        => $wp_owner,
    group       => $wp_group,
  }

  ## Configure wordpress
  #
  concat { "${install_dir}/wp-config.php":
    owner   => $wp_owner,
    group   => $wp_group,
    mode    => '0640',
    require => Exec["Extract wordpress ${install_dir}"],
  }
  if $wp_config_content {
    concat::fragment { "${install_dir}/wp-config.php body":
      target  => "${install_dir}/wp-config.php",
      content => $wp_config_content,
      order   => '20',
    }
  } else {
    # Template uses no variables
    file { "${install_dir}/wp-keysalts.php":
      ensure  => present,
      content => template('wordpress/wp-keysalts.php.erb'),
      replace => false,
      require => Exec["Extract wordpress ${install_dir}"],
    }
    concat::fragment { "${install_dir}/wp-config.php keysalts":
      target  => "${install_dir}/wp-config.php",
      source  => "${install_dir}/wp-keysalts.php",
      order   => '15',
      require => File["${install_dir}/wp-keysalts.php"],
    }
    concat::fragment { "${install_dir}/wp-config.php w3-cache":
      target  => "${install_dir}/wp-config.php",
      content => template('wordpress/wp-w3-cache.php.erb'),
      order   => '14',
      require => Exec["Extract wordpress ${install_dir}"],
    }
    concat::fragment { "${install_dir}/wp-config.php config-header":
      target  => "${install_dir}/wp-config.php",
      content => template('wordpress/wp-config-header.php.erb'),
      order   => '10',
      require => Exec["Extract wordpress ${install_dir}"],
    }
    # Template uses:
    # - $db_name
    # - $db_user
    # - $db_password
    # - $db_host
    # - $wp_table_prefix
    # - $wp_lang
    # - $wp_plugin_dir
    # - $wp_proxy_host
    # - $wp_proxy_port
    # - $wp_multisite
    # - $wp_site_domain
    # - $wp_additional_config
    # - $wp_debug
    # - $wp_debug_log
    # - $wp_debug_display
    concat::fragment { "${install_dir}/wp-config.php body":
      target  => "${install_dir}/wp-config.php",
      content => template('wordpress/wp-config.php.erb'),
      order   => '20',
    }
  }
}
