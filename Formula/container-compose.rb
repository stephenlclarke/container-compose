class ContainerCompose < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  license "Apache-2.0"
  head "https://github.com/stephenlclarke/container-compose.git", branch: "develop"

  depends_on "container"
  depends_on "go" => :build
  depends_on xcode: ["26.0", :build]
  depends_on arch: :arm64
  depends_on macos: :sequoia

  resource "container" do
    url "https://github.com/stephenlclarke/container/archive/7c761e0ab4db9ba74715ca8615fcf1fd7c9cdfab.tar.gz"
    sha256 "7f49354d4c948f1d90ea2c2bad62c4d64f4c5b09837d9ee55c671dd2e20aa74d"
  end

  def install
    resource("container").stage buildpath.parent/"container"

    system "swift", "build", "--disable-sandbox", "--configuration", "release", "--product", "compose"

    cd "Tools/compose-normalizer" do
      system "go", "build", "-o", "compose-normalizer", "."
    end

    plugin = libexec/"container-plugins/compose"
    (plugin/"bin").install ".build/release/compose"
    plugin.install "config.toml"
    (plugin/"resources").install "Tools/compose-normalizer/compose-normalizer"

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

      This formula builds against stephenlclarke/container at:
        7c761e0ab4db9ba74715ca8615fcf1fd7c9cdfab
    EOS
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/container-compose version --short")
    assert_predicate libexec/"container-plugins/compose/config.toml", :exist?
    assert_predicate libexec/"container-plugins/compose/resources/compose-normalizer", :executable?
  end
end
