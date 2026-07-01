class ContainerCompose < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose/releases/download/0.5.0/container-compose-plugin-release-arm64.tar.gz"
  version "0.5.0"
  sha256 "5bf9a95eaeb08d0f396c2315812e6f956fadd301c06428e1fc7700ff6b67e86b"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on "stephenlclarke/tap/container"

  def install
    plugin = libexec/"container-plugins/compose"
    payload = (buildpath/"compose").directory? ? Dir["compose/*"] : Dir["*"]
    plugin.install payload

    bin.install_symlink plugin/"bin/compose" => "container-compose"
  end

  def post_install
    plugin = opt_libexec/"container-plugins/compose"
    plugin_dir = formula_opt_prefix("stephenlclarke/tap/container")/"libexec/container-plugins"
    plugin_dir.mkpath

    plugin_link = plugin_dir/"compose"
    if plugin_link.symlink? || plugin_link.file?
      rm plugin_link
    elsif plugin_link.directory?
      rm_r plugin_link
    end

    ln_s plugin, plugin_link
  end

  def caveats
    <<~EOS
      The plugin is installed under:
        #{opt_libexec}/container-plugins/compose

      This formula links the plugin into the active container install root.
      Restart stephenlclarke/tap/container after installing or upgrading this plugin:
        brew services restart stephenlclarke/tap/container

      This formula installs the stable release prebuilt package asset:
        container-compose-plugin-release-arm64.tar.gz
    EOS
  end

  test do
    assert_match "0.5.0", shell_output("#{bin}/container-compose version --short")
    assert_path_exists libexec/"container-plugins/compose/config.toml"
    assert_predicate libexec/"container-plugins/compose/resources/compose-normalizer", :executable?

    plugin_link = formula_opt_prefix("stephenlclarke/tap/container")/"libexec/container-plugins/compose"
    assert_predicate plugin_link, :symlink?
    assert_equal opt_libexec/"container-plugins/compose", plugin_link.readlink
  end
end
