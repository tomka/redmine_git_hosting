module GitHosting
    class GitoliteConfig
	DUMMY_REDMINE_KEY="redmine_dummy_key"
	ARCHIVED_REDMINE_KEY="redmine_archived_project"
	DISABLED_REDMINE_KEY="redmine_disabled_project"
	GIT_DAEMON_KEY="daemon"
	ADMIN_REPO = "gitolite-admin"
	PRIMARY_CONF_FILE = "gitolite.conf"
	DEFAULT_ADMIN_KEY_NAME = "id_rsa"

	def self.gitolite_conf
	    Setting.plugin_redmine_git_hosting['gitConfigFile'] || PRIMARY_CONF_FILE
	end

	def self.default_conf?
	    gitolite_conf == PRIMARY_CONF_FILE
	end

	# Need admin key if conf file is default file or if there was an admin key.
	def self.has_admin_key?
	    Setting.plugin_redmine_git_hosting['gitConfigHasAdminKey'] != 'false' || default_conf?
	end

	def initialize file_path
	    @path = file_path
	    load
	end

	def logger
	    return GitHosting.logger
	end

	def save
	    begin
		File.open(@path, "w") do |f|
		    f.puts content
		end
		@original_content = content
	    rescue => e
		GitHosting.logger.error "Error trying to write config file: #{e.to_s}"
	    end
	end

	def add_write_user repo_name, users
	    repository(repo_name).add "RW+", users.sort
	end

	def set_write_user repo_name, users
	    repository(repo_name).set "RW+", users.sort
	end

	def add_read_user repo_name, users
	    repository(repo_name).add "R", users.sort
	end

	def set_read_user repo_name, users
	    repository(repo_name).set "R", users.sort
	end

	def mark_with_dummy_key repo_name
	    add_read_user repo_name, [DUMMY_REDMINE_KEY]
	end

	def mark_archived repo_name
	    add_read_user repo_name, [ARCHIVED_REDMINE_KEY]
	end

	def mark_disabled repo_name
	    add_read_user repo_name, [DISABLED_REDMINE_KEY]
	end

	# Grab admin key (assuming it exists)
	def get_admin_key
	    return (repository(ADMIN_REPO).get "RW+").first
	end

	def set_admin_key new_name
	    repository(ADMIN_REPO).set "RW+", new_name
	end

	def delete_repo repo_name
	    @repositories.delete(repo_name)
	end

	def rename_repo old_name, new_name
	    if @repositories.has_key?(old_name)
		perms = @repositories.delete(old_name)
		@repositories[new_name] = perms
	    end
	end

	# A repository is a "redmine" repository if it has redmine keys or no keys
	# (latter case is checked, since we end up adding the DUMMY_REDMINE_KEY to
	# a repository with no keys anyway....
	def is_redmine_repo? repo_name
	    repository(repo_name).rights.detect {|perm, users| users.detect {|key| is_redmine_key? key}} || (repo_has_no_keys? repo_name)
	end

	# Return true if repository has any redmine keys other than the DUMMY_REDMINE_KEY
	def has_actual_redmine_keys? repo_name
	    repository(repo_name).rights.detect {|perm, users| users.detect {|key| GitolitePublicKey::ident_to_user_token(key)}}
	end

	# Delete all of the redmine keys from a repository
	# In addition, if there are any redmine keys, delete the GIT_DAEMON_KEY as well,
	# since we assume this under control of redmine server.
	def delete_redmine_keys repo_name
	    return unless @repositories[repo_name] && is_redmine_repo?(repo_name)

	    repository(repo_name).rights.each do |perm, users|
		users.delete_if {|key| ((is_redmine_key? key) || (is_daemon_key? key))}
	    end
	end

	def repo_has_no_keys? repo_name
	    !repository(repo_name).rights.detect {|perm, users| users.length > 0}
	end

	def is_redmine_key? keyname
	    (GitolitePublicKey::ident_to_user_token(keyname) || keyname == DUMMY_REDMINE_KEY || keyname == ARCHIVED_REDMINE_KEY || keyname == DISABLED_REDMINE_KEY) ? true : false
	end

	def is_daemon_key? keyname
	    (keyname == GIT_DAEMON_KEY)
	end

	def changed?
	    @original_content != content
	end

	def all_repos
	    repos={}
	    @repositories.each do |repo, rights|
		repos[repo] = 1
	    end
	    return repos
	end

	# For redmine repos, return map of basename (unique for redmine repos) => repo path
	def redmine_repo_map
	    redmine_repos=Hash.new{|hash, key| hash[key] = []}	# default -- empty list
	    @repositories.each do |repo, rights|
		if is_redmine_repo? repo
		    # Represents bug in conf file, but must allow more than one
		    mybase = File.basename(repo)
		    redmine_repos[mybase] << repo
		end
	    end
	    return redmine_repos
	end

	def self.gitolite_repository_map
	    gitolite_repos=Hash.new{|hash, key| hash[key] = []}	 # default -- empty list
	    myfiles = %x[#{GitHosting.git_user_runner} 'find #{GitHosting.repository_base} -type d -name "*.git" -prune -print'].chomp.split("\n")
	    filesplit = /^(\.\/)*#{GitHosting.repository_base}(.*?)([^\/]+)\.git$/
	    myfiles.each do |nextfile|
		if filesplit =~ nextfile
		    gitolite_repos[$3] << "#{$2}#{$3}"
		end
	    end
	    gitolite_repos
	end

	private
	def load
	    @original_content = []
	    @repositories = ActiveSupport::OrderedHash.new
	    begin
		cur_repo_name = nil
		File.open(@path).each_line do |line|
		    @original_content << line
		    tokens = line.strip.split
		    if tokens.first == 'repo'
			cur_repo_name = tokens.last
			@repositories[cur_repo_name] = GitoliteAccessRights.new
			next
		    end
		    cur_repo_right = @repositories[cur_repo_name]
		    if cur_repo_right and tokens[1] == '='
			cur_repo_right.add tokens.first, tokens[2..-1]
		    end
		end
		# If no admin key in repo, delete any residual
		@repositories.delete(ADMIN_REPO) unless self.class.has_admin_key?

		@original_content = @original_content.join
	    rescue => e
		GitHosting.logger.error "Error trying to read config file: #{e.to_s}"
	    end
	end

	def repository repo_name
	    @repositories[repo_name] ||= GitoliteAccessRights.new
	end

	def content
	    content = []

	    if self.class.has_admin_key?
		# Make sure that admin repo is first
		content << "repo\t#{ADMIN_REPO}"
		admin_key = @repositories[ADMIN_REPO] && (@repositories[ADMIN_REPO].get "RW+").first
		unless admin_key.nil?
		    # Put in a single admin key
		    content << "\tRW+\t=\t#{admin_key}"
		else
		    # If no repo, put in a default -- will try to fix later if problem.
		    content << "\tRW+\t=\t#{DEFAULT_ADMIN_KEY_NAME}"
		end
		content << ""
	    end

	    @repositories.each do |repo, rights|
		unless repo == ADMIN_REPO
		    content << "repo\t#{repo}"
		    has_users=false
		    rights.each do |perm, users|
			if users.length > 0
			    has_users=true
			    content << "\t#{perm}\t=\t#{users.join(' ')}"
			end
		    end
		    if !has_users
			# If no users, use dummy key to make sure repo created
			content << "\tR\t=\t#{DUMMY_REDMINE_KEY}"
		    end
		    content << ""
		end
	    end
	    return content.join("\n")
	end
    end

    class GitoliteAccessRights
	def initialize
	    @rights = ActiveSupport::OrderedHash.new
	end

	def rights
	    @rights
	end

	def add perm, users
	    @rights[perm.to_sym] ||= []
	    @rights[perm.to_sym] << users
	    @rights[perm.to_sym].flatten!
	    @rights[perm.to_sym].uniq!
	end

	def set perm, users
	    @rights[perm.to_sym] = []
	    add perm, users
	end

	def get perm
	    @rights[perm.to_sym] || []
	end

	def each
	    @rights.each {|k,v| yield k, v}
	end
    end
end
