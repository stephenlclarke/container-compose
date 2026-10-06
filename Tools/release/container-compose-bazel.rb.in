require "digest"

class ContainerCompose < Formula
  desc "Docker Compose style plugin for Apple's container CLI"
  homepage "https://github.com/stephenlclarke/container-compose"
  url "https://github.com/stephenlclarke/container-compose/releases/download/0.16.0/container-compose-plugin-release-arm64.tar.gz"
  sha256 "7dce00576a822a386d53047dad2a8c7e38de5f2b6e6e3e4e4bb074e95d65dfdc"
  license "Apache-2.0"

  depends_on arch: :arm64
  depends_on macos: :sequoia
  depends_on "stephenlclarke/tap/container"

  resource "signed-payload" do
    url "https://github.com/stephenlclarke/container-compose/releases/download/0.16.0/container-compose-plugin-release-arm64.tar.gz"
    sha256 "7dce00576a822a386d53047dad2a8c7e38de5f2b6e6e3e4e4bb074e95d65dfdc"
  end

  def install
    plugin = libexec/"container-plugins/compose"
    payload = (buildpath/"compose").directory? ? Dir["compose/*"] : Dir["*"]
    plugin.install payload

    bin.install_symlink plugin/"bin/compose" => "container-compose"
  end

  def post_install
    resource("signed-payload").stage do
      source_root = Pathname.pwd.realpath
      source_root /= "compose" if (source_root/"compose").directory?
      restore_signed_files(source_root, [
        %w[
          bin/compose
          libexec/container-plugins/compose/bin/compose
          4f59ea3553e19555bf7fc0eb3a9c0ed05342a45fbc6ef12819c165a7336cc098
        ],
        %w[
          resources/compose-normalizer
          libexec/container-plugins/compose/resources/compose-normalizer
          b726552fbd2e7436b82f72b0494f06fb1d2bc6fc94d71de4a318fb42d93599bb
        ],
      ])
    end
  end

  def restore_signed_files(source_root, files)
    runtime_root = prefix.realpath
    if runtime_root != prefix || File.stat(runtime_root).uid != Process.uid
      odie "Signed payload destination keg is aliased"
    end
    admitted = files.map do |source_name, destination_name, expected|
      escaped = [source_name, destination_name].any? do |name|
        Pathname.new(name).absolute? || name.split("/").include?("..")
      end
      if escaped
        odie "Signed payload path escapes its admitted root"
      end
      source = source_root/source_name
      destination = prefix/destination_name
      if !source.file? || source.symlink? || source.realpath != source ||
         Digest::SHA256.file(source).hexdigest != expected
        odie "Immutable signed payload source differs"
      end
      if !destination.file? || destination.symlink? || File.lstat(destination).nlink != 1 ||
         File.stat(destination).uid != Process.uid
        odie "Signed payload destination is not an owned regular file"
      end
      parent = destination.parent
      until parent == prefix
        if !parent.directory? || parent.symlink? || parent.realpath != parent || File.stat(parent).uid != Process.uid
          odie "Signed payload destination parent is aliased"
        end
        parent = parent.parent
      end
      [source, destination, expected]
    end
    admitted.each do |source, destination, expected|
      temporary = destination.parent/".#{destination.basename}.signed-restore-#{Process.pid}"
      created = nil
      begin
        File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0755) do |output|
          created = [output.stat.dev, output.stat.ino]
          File.open(source, File::RDONLY | File::NOFOLLOW) { |input| IO.copy_stream(input, output) }
          output.flush
          output.fsync
        end
        odie "Restored signed payload bytes differ" if Digest::SHA256.file(temporary).hexdigest != expected
        if destination.symlink? || !destination.file? || File.lstat(destination).nlink != 1 ||
           destination.parent.realpath != destination.parent
          odie "Signed payload destination changed before replacement"
        end
        File.rename(temporary, destination)
        odie "Installed signed payload bytes differ" if Digest::SHA256.file(destination).hexdigest != expected
      ensure
        if created && temporary.exist? && !temporary.symlink? &&
           [File.lstat(temporary).dev, File.lstat(temporary).ino] == created
          File.unlink(temporary)
        end
      end
    end
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
    assert_match "0.16.0", shell_output("#{bin}/container-compose version --short")
    assert_path_exists libexec/"container-plugins/compose/config.toml"
    assert_path_exists libexec/"container-plugins/compose/resources/container-compose-icon.png"
    assert_predicate libexec/"container-plugins/compose/resources/compose-normalizer", :executable?
    initializer = libexec/"container-plugins/compose/resources/volume-initializer"
    assert_predicate initializer/"compose-volume-initializer-linux-arm64", :executable?
    assert_predicate initializer/"compose-volume-initializer-linux-amd64", :executable?
  end
end
