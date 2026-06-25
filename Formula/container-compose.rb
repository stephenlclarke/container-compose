class ContainerCompose < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose/releases/download/homebrew-develop/container-compose-plugin-develop-debug-arm64.tar.gz"
  sha256 :no_check
  version "develop-debug"
  license "Apache-2.0"

  depends_on "container"
  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    plugin = libexec/"container-plugins/compose"
    plugin.install Dir["compose/*"]

    bin.install_symlink plugin/"bin/compose" => "container-compose"
  end

  def caveats
    <<~EOS
      The plugin is installed under:
        #{opt_libexec}/container-plugins/compose

      To make the Homebrew-installed container CLI discover it, link it into
      container's user plugin directory and restart the container service:
        mkdir -p "$(brew --prefix container)/libexec/container-plugins"
        ln -sfn "#{opt_libexec}/container-plugins/compose" "$(brew --prefix container)/libexec/container-plugins/compose"
        brew services restart container

      This formula installs the develop debug prebuilt release asset:
        container-compose-plugin-develop-debug-arm64.tar.gz
    EOS
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/container-compose version --short")
    assert_predicate libexec/"container-plugins/compose/config.toml", :exist?
    assert_predicate libexec/"container-plugins/compose/resources/compose-normalizer", :executable?
  end
end
