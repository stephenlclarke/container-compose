class ContainerCompose < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose/releases/download/0.6.40/container-compose-plugin-release-arm64.tar.gz"
  version "0.6.40"
  sha256 "47c777a9edd76dde3e90876a3a57f7385fa9a07574f282d24f656a87c17592d6"
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

  def caveats
    <<~EOS
      The plugin is installed under:
        #{opt_libexec}/container-plugins/compose

      The container formula owns the plugin registration link. Refresh it and
      restart stephenlclarke/tap/container after installing or upgrading this plugin:
        brew postinstall stephenlclarke/tap/container
        brew services restart stephenlclarke/tap/container

      This formula installs the stable release prebuilt package asset:
        container-compose-plugin-release-arm64.tar.gz
    EOS
  end

  test do
    assert_match "0.6.40", shell_output("#{bin}/container-compose version --short")
    assert_path_exists libexec/"container-plugins/compose/config.toml"
    assert_predicate libexec/"container-plugins/compose/resources/compose-normalizer", :executable?
  end
end
