require 'log4r'

require 'vagrant/util/platform'

module Vagrant
  module Hosts
    # Represents a BSD host, such as FreeBSD and Darwin (Mac OS X).
    class BSD < Base
      include Util
      include Util::Retryable

      def self.match?
        Util::Platform.darwin? || Util::Platform.bsd?
      end

      def self.precedence
        # Set a lower precedence because this is a generic OS. We
        # want specific distros to match first.
        2
      end

      def initialize(*args)
        super

        @logger = Log4r::Logger.new("vagrant::hosts::bsd")
        @nfs_restart_command = "sudo nfsd restart"
        @nfs_exports_template = "nfs/exports"
      end

      # Create the sudoers.d directory, update /etc/sudoers, and create /etc/sudoers.d/vagrant
      # https://developer.apple.com/library/mac/documentation/Darwin/Reference/ManPages/man5/sudoers.5.html
      def create_vagrant_sudoers_policy
        sudoersd_dir = '/etc/sudoers.d'

        # This block should only run the first time vagrant is run on a new host
        unless File.exists? "#{sudoersd_dir}/vagrant"
          sudoers_file = '/etc/sudoers'
          sudoers_include = '\n#includedir /etc/sudoers.d'
          vagrant_sudoersd_filename = "#{sudoersd_dir}/vagrant"
          # We cannot use heredoc since echo doesn't handle the multiline input properly
          content = "# Allow passwordless startup of Vagrant when using NFS.\nCmnd_Alias VAGRANT_EXPORTS_ADD = /usr/bin/su root -c echo '*' >> /etc/exports\nCmnd_Alias VAGRANT_NFSD = /sbin/nfsd restart\nCmnd_Alias VAGRANT_EXPORTS_REMOVE = /usr/bin/sed -e /*/ d -ibak /etc/exports\n%staff ALL=(root) NOPASSWD: VAGRANT_EXPORTS_ADD, VAGRANT_NFSD, VAGRANT_EXPORTS_REMOVE\n"

          # To avoid breaking sudo, we must create this directory before updating /etc/sudoers
          @ui.info "creating #{sudoersd_dir}"
          result = system "sudo mkdir #{sudoersd_dir}"
          raise StandardError, "sudo mkdir #{sudoersd_dir} failed" unless result

          # Use backticks to capture stdout
          sudoers = `sudo cat #{sudoers_file}`
          unless sudoers.include? sudoers_include
            @ui.info "Adding '#{sudoers_include}' to #{sudoers_file}"
            result = system "echo '#{sudoers_include}' | sudo tee -a #{sudoers_file}"
            raise StandardError, "echo '#{sudoers_include}' | sudo tee -a #{sudoers_file} failed" unless result
          end

          @ui.info "Adding #{sudoersd_dir}/vagrant file"
          result = system "echo '#{content}' | sudo tee #{vagrant_sudoersd_filename}"
          raise StandardError, "echo '#{content}' | sudo tee #{vagrant_sudoersd_filename} failed" unless result

          @ui.info "Updating #{sudoersd_dir}/vagrant permissions to 0440"
          result = system "sudo chmod 0440 #{vagrant_sudoersd_filename}"
          raise StandardError,  "sudo chmod 0440 #{vagrant_sudoersd_filename} failed" unless result
        end
      end

      def nfs?
        retryable(:tries => 10, :on => TypeError) do
          system("which nfsd > /dev/null 2>&1")
        end
      end

      def nfs_export(id, ip, folders)
        output = TemplateRenderer.render(@nfs_exports_template,
                                         :uuid => id,
                                         :ip => ip,
                                         :folders => folders)

        # The sleep ensures that the output is truly flushed before any `sudo`
        # commands are issued.
        @ui.info I18n.t("vagrant.hosts.bsd.nfs_export")
        sleep 0.5

        # First, clean up the old entry
        nfs_cleanup(id)

        # Output the rendered template into the exports
        output.split("\n").each do |line|
          line = line.gsub('"', '\"')
          system(%Q[sudo su root -c "echo '#{line}' >> /etc/exports"])
        end

        # We run restart here instead of "update" just in case nfsd
        # is not starting
        system(@nfs_restart_command)
      end

      def nfs_prune(valid_ids)
        return if !File.exist?("/etc/exports")

        @logger.info("Pruning invalid NFS entries...")

        output = false

        File.read("/etc/exports").lines.each do |line|
          if line =~ /^# VAGRANT-BEGIN: (.+?)$/
            if valid_ids.include?($1.to_s)
              @logger.debug("Valid ID: #{$1.to_s}")
            else
              if !output
                # We want to warn the user but we only want to output once
                @ui.info I18n.t("vagrant.hosts.bsd.nfs_prune")
                output = true
              end

              @logger.info("Invalid ID, pruning: #{$1.to_s}")
              nfs_cleanup($1.to_s)
            end
          end
        end
      end

      protected

      def nfs_cleanup(id)
        create_vagrant_sudoers_policy

        return if !File.exist?("/etc/exports")

        # Use sed to just strip out the block of code which was inserted
        # by Vagrant, and restart NFS.
        system("sudo sed -e '/^# VAGRANT-BEGIN: #{id}/,/^# VAGRANT-END: #{id}/ d' -ibak /etc/exports")
      end
    end
  end
end
