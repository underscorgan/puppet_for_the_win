#! /usr/bin/env ruby

# This rakefile is meant to be run from within the [Puppet Win
# Builder](http://links.puppetlabs.com/puppetwinbuilder) tree.

# Load Rake
begin
  require 'rake'
rescue LoadError
  require 'rubygems'
  require 'rake'
end

require 'rake/clean'

# Added download task from buildr
require 'rake/downloadtask'

# Where we're situated in the filesystem relative to the Rakefile
TOPDIR=File.expand_path(File.join(File.dirname(__FILE__), "..", ".."))

# Produce a wixobj from a wxs file.
def candle(wxs_file, basedir)
  Dir.chdir File.join(TOPDIR, File.dirname(wxs_file)) do
    sh "candle -ext WixUIExtension -dStageDir=#{basedir} #{File.basename(wxs_file)}"
  end
end

# Produce a wxs file from a directory in the stagedir
# e.g. heat('wxs/fragments/foo.wxs', 'stagedir/sys/foo')
def heat(wxs_file, stage_dir)
  Dir.chdir TOPDIR do
    cg_name = File.basename(wxs_file.ext(''))
    dir_ref = File.basename(File.dirname(stage_dir))
    # NOTE:  The reference specified using the -dr flag MUST exist in the
    # parent puppet.wxs file.  Otherwise, WiX won't be able to graft the
    # fragment into the right place in the package.
    dir_ref = 'INSTALLDIR' if dir_ref == 'stagedir'
    sh "heat dir #{stage_dir} -v -ke -indent 2 -cg #{cg_name} -gg -dr #{dir_ref} -var var.StageDir -out #{wxs_file}"
  end
end

def unzip(zip_file, dir)
  Dir.chdir TOPDIR do
    Dir.chdir dir do
      sh "7za -y x #{File.join(TOPDIR, zip_file)}"
    end
  end
end

def gitclone(target, uri)
  Dir.chdir(File.dirname(target)) do
    sh "git clone #{uri} #{File.basename(target)}"
  end
end

CLOBBER.include('downloads/*')
CLEAN.include('stagedir/*')
CLEAN.include('wix/fragments/*.wxs')
CLEAN.include('wix/**/*.wixobj')
CLEAN.include('pkg/*')

namespace :windows do
  # These are file tasks that behave like mkdir -p
  directory 'pkg'
  directory 'downloads'
  directory 'stagedir/sys'
  directory 'wix/fragments'

  ## File Lists

  TARGETS = FileList['pkg/puppet.msi']

  # These translate to ZIP files we'll download
  # FEATURES = %w{ ruby git wix misc }
  FEATURES = %w{ ruby }
  # These are the applications we're packaging from VCS source
  APPS = %w{ facter puppet }
  # Thse are the pre-compiled things we need to stage and include in
  # the packages
  DOWNLOADS = FEATURES.collect { |fn| File.join("downloads", fn.ext('zip')) }

  # We do this to provide a cache of sorts, allowing rake clean to clean but
  # preventing the build tasks from having to re-clone all of puppet and facter
  # which usually takes ~ 3 minutes.
  GITREPOS  = APPS.collect { |fn| File.join("downloads", fn.ext('')) }

  # These are the VCS repositories checked out into downloads.
  # For example, downloads/puppet and downloads/facter
  GITREPOS.each do |repo|
    file repo, [:uri] => ['downloads'] do |t, args|
      args.with_defaults(:uri => "git://github.com/puppetlabs/#{File.basename(t.name).ext('.git')}")
      Dir.chdir File.dirname(t.name) do
        sh "git clone #{args[:uri]} #{File.basename(t.name)}"
      end
    end

    # These tasks are not meant to be executed every build They're meant to
    # provide the means to checkout the reference we want prior to running the
    # build.  See the windows:checkout task for more information
    task "checkout.#{File.basename(repo.ext(''))}", [:ref] => [repo] do |t, args|
      repo_dir = t.name.gsub(/^.*?checkout\./, 'downloads/')
      args.with_defaults(:ref => 'refs/remotes/origin/master')
      Dir.chdir repo_dir do
        sh 'git fetch origin'
        sh 'git fetch origin --tags'
        # We explicitly avoid using git clean -x because we rely on rake clean
        # to clean up build artifacts.  Specifically, we don't want to clone
        # and download zip files every single build
        sh 'git clean -f -d'
        sh "git checkout -f #{args[:ref]}"
      end
    end
  end

  # There is a 1:1 mapping between a wxs file and a wixobj file
  # The wxs files in the top level of wix/ should be committed to VCS
  WXSFILES = FileList['wix/*.wxs']
  # WXS Fragments could have different types of sources and are generated
  # during the build process by heat.exe
  WXS_FRAGMENTS_HASH = {
    'ruby' => { :src => 'stagedir/sys/ruby' },
    'puppet' => { :src => 'stagedir/puppet' },
    'facter' => { :src => 'stagedir/facter' },
  }

  # Additional directories to stage as fragments automatically.
  # conf/windows/stagedir/bin/ for example.
  FileList[File.join(TOPDIR, 'conf', 'windows', 'stage', '*')].each do |fn|
    my_topdir = File.basename(fn)
    WXS_FRAGMENTS_HASH[my_topdir] = { :src => "stagedir/#{my_topdir}" }
    file "stagedir/#{my_topdir}" => ["stagedir"] do |t|
      src = File.join(TOPDIR, 'conf', 'windows', 'stage', File.basename(t.name))
      dst = t.name
      FileUtils.cp_r src, dst
    end
    task :stage => ["stagedir/#{my_topdir}"]
  end

  # These files should be auto-generated by heat
  WXS_FRAGMENTS = WXS_FRAGMENTS_HASH.keys.collect do |fn|
    File.join("wix", "fragments", fn.ext('wxs'))
  end
  # All of the objects we need to create
  WIXOBJS = (WXSFILES + WXS_FRAGMENTS).ext('wixobj')
  # These directories should be unpacked into stagedir/sys
  SYSTOOLS = FEATURES.collect { |fn| File.join("stagedir", "sys", fn) }

  task :default => :build
  # High Level Tasks.  Other tasks will add themselves to these tasks
  # dependencies.

  # This is also called from the build script in the Puppet Win Builder archive.
  # This will be called AFTER the update task in a new process.
  desc "Build puppet.msi"
  task :build => "pkg/puppet.msi"

  desc "Download example"
  task :download => DOWNLOADS

  # Note, other tasks may append themselves as necessary for the stage task.
  desc "Stage everything to be built"
  task :stage => SYSTOOLS

  desc "Clone upstream repositories"
  task :clone, [:puppet_uri, :facter_uri] => ['downloads'] do |t, args|
    baseuri = "git://github.com/puppetlabs"
    args.with_defaults(:puppet_uri => "#{baseuri}/puppet.git",
                       :facter_uri => "#{baseuri}/facter.git")
    Rake::Task["downloads/puppet"].invoke(args[:puppet_uri])
    Rake::Task["downloads/facter"].invoke(args[:facter_uri])
  end

  desc "Checkout app repositories to a specific ref"
  task :checkout, [:puppet_ref, :facter_ref] => [:clone] do |t, args|
    # args.with_defaults(:puppet_ref => 'refs/remotes/origin/2.7.x',
    #                    :facter_ref => 'refs/remotes/origin/1.6.x')
    args.with_defaults(:puppet_ref => 'refs/tags/2.7.9',
                       :facter_ref => 'refs/tags/1.6.4')
    # This is an example of how to invoke other tasks that take parameters from
    # a task that takes parameters.
    Rake::Task["windows:checkout.facter"].invoke(args[:facter_ref])
    Rake::Task["windows:checkout.puppet"].invoke(args[:puppet_ref])
  end

  desc "List available rake tasks"
  task :help do
    sh 'rake -T'
  end

  # The update task is always called from the build script
  # This gives the repository an opportunity to update itself
  # and manage how it updates itself.
  desc "Update the build scripts"
  task :update do
    sh 'git pull'
  end

  # Tasks to unpack the zip files
  SYSTOOLS.each do |systool|
    zip_file = File.join("downloads", File.basename(systool).ext('zip'))
    file systool => [ zip_file, File.dirname(systool) ] do
      unzip(zip_file, File.dirname(systool))
    end
  end

  DOWNLOADS.each do |fn|
    file fn => [ File.dirname(fn) ] do |t|
      download t.name => "http://downloads.puppetlabs.com/development/ftw/#{File.basename(t.name)}"
    end
  end

  WIXOBJS.each do |wixobj|
    source_dir = WXS_FRAGMENTS_HASH[File.basename(wixobj.ext(''))][:src]
    file wixobj => [ wixobj.ext('wxs'), File.dirname(wixobj) ] do |t|
      candle(t.name.ext('wxs'), source_dir)
    end
  end

  WXS_FRAGMENTS.each do |wxs_frag|
    source_dir = WXS_FRAGMENTS_HASH[File.basename(wxs_frag.ext(''))][:src]
    file wxs_frag => [ source_dir, File.dirname(wxs_frag) ] do |t|
      heat(t.name, source_dir)
    end
  end

  # We stage whatever is checked out using the checkout parameterized task.
  APPS.each do |app|
    file "stagedir/#{app}" => ['stagedir', "downloads/#{app}"] do |t|
      my_app = File.basename(t.name.ext(''))
      puts "Copying downloads/#{my_app} to #{t.name} ..."
      FileUtils.mkdir_p t.name
      # This avoids copying hidden files like .gitignore and .git
      FileUtils.cp_r FileList["downloads/#{my_app}/*"], t.name
    end
    # The stage task needs these directories to be in place.
    task :stage => ["stagedir/#{app}"]
  end

  ####### REVISIT
  file 'pkg/puppet.msi' => WIXOBJS do |t|
    sh "light -ext WixUIExtension -cultures:en-us #{t.prerequisites.join(' ')} -out #{t.name}"
  end

  desc 'Install the MSI using msiexec'
  task :install => [ 'pkg/puppet.msi', 'pkg' ] do |t|
    Dir.chdir "pkg" do
      sh 'msiexec /q /l*v install.txt /i puppet.msi INSTALLDIR="C:\test\puppet" PUPPET_MASTER_HOSTNAME="puppetmaster"'
    end
  end

  desc 'Uninstall the MSI using msiexec'
  task :uninstall => [ 'pkg/puppet.msi', 'pkg' ] do |t|
    Dir.chdir "pkg" do
      sh 'msiexec /qn /l*v uninstall.txt /x puppet.msi'
    end
  end
end
