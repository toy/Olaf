#!/usr/bin/env ruby

# Olaf: Overly Lightweight Acoustic Fingerprinting
# Copyright (C) 2019-2023  Joren Six

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.

# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

require 'json'
require 'fileutils'
require 'tempfile'
require 'open3'
require 'find'

DB_FOLDER = File.expand_path("~/.olaf/db") #needs to be the same in the c code
CACHE_FOLDER = File.expand_path("~/.olaf/cache") #needs to be the same in the c code
EXECUTABLE_LOCATION = "/usr/local/bin/olaf_c"
CHECK_INCOMING_AUDIO = true
SKIP_DUPLICATES = true
MONITOR_LENGTH_IN_SECONDS = 7
TARGET_SAMPLE_RATE = 16000

ALLOWED_AUDIO_FILE_EXTENSIONS = "**/*.{m4a,wav,mp4,wv,ape,ogg,mp3,raw,flac,wma,M4A,WAV,MP4,WV,APE,OGG,MP3,FLAC,WMA}"
AUDIO_DURATION_COMMAND = "ffprobe -i \"__input__\" -show_entries format=duration -v quiet -of csv=\"p=0\""
AUDIO_CONVERT_COMMAND = "ffmpeg -hide_banner -y -loglevel panic  -i \"__input__\" -ac 1 -ar #{TARGET_SAMPLE_RATE} -f f32le -acodec pcm_f32le \"__output__\""
AUDIO_CONVERT_FROM_RAW_COMMAND = "ffmpeg -hide_banner -y -loglevel panic  -ac 1 -ar #{TARGET_SAMPLE_RATE} -f f32le -acodec pcm_f32le -i \"__input__\"  \"__output__\""
AUDIO_CONVERT_COMMAND_WITH_START_DURATION = "ffmpeg -hide_banner -y -loglevel panic -ss __start__ -i \"__input__\" -t __duration__ -ac 1 -ar #{TARGET_SAMPLE_RATE} -f f32le -acodec pcm_f32le \"__output__\""
MIC_INPUT = "ffmpeg -hide_banner -loglevel panic  -f avfoundation -i 'none:default' -ac 1 -ar #{TARGET_SAMPLE_RATE} -f f32le -acodec pcm_f32le pipe:1"

#alt mic input: sox -d -t raw -b 32 -e float -c 1  -r 16000 - | ./bin/olaf_mem query

#expand the argument to a list of files to process.
# a file is simply added to the list
# a text file is read and each line is interpreted as a path to a file
# for a folder each audio file within that folder (and subfolders) is added to the list
def audio_file_list(arg,files_to_process)
  arg = File.expand_path(arg)
  if File.directory?(arg)
    audio_files_in_dir = Dir.glob(File.join(arg,ALLOWED_AUDIO_FILE_EXTENSIONS))
    audio_files_in_dir.each do |audio_filename|
      files_to_process << audio_filename
    end
  elsif File.extname(arg).eql? ".txt"
    audio_files_in_txt = File.read(arg).split("\n")
    audio_files_in_txt.each do |audio_filename|
      audio_filename = File.expand_path(audio_filename)
      if File.exist?(audio_filename)
        files_to_process << audio_filename
      else
        STDERR.puts "Could not find: #{audio_filename}"
      end
    end
  elsif File.exist? arg
    files_to_process << arg
  else
    STDERR.puts "Could not find: #{arg}"
  end
  files_to_process
end

#Folder size in MB
def folder_size(folder)
  folder = folder
  total_size = 0
  Find.find(folder) do |path|
    if File.file?(path)
      total_size += File.size(path)
    end
  end
  total_size / (1024.0 * 1024.0)
end


def has(audio_file)
  #return false if no db exits
  return false if (Dir.glob(File.join(DB_FOLDER,"*")).size == 0)
  
  result = `#{EXECUTABLE_LOCATION} has '#{audio_file}'`
  unless(result.empty?)
    result_line = result.split("\n")[1]
    result_line.split(";").size > 1
  else
    false
  end
end

def audio_file_duration(audio_file)
  duration_command = AUDIO_DURATION_COMMAND.gsub("__input__",audio_file)
  `#{duration_command}`.to_f
end

def batch_monitor(index,length,audio_filename,ignore_self_match, skip_size)
  audio_filename = File.expand_path(audio_filename)
  audio_filename_escaped = escape_audio_filename(audio_filename)
  audio_identifier = `olaf_c name_to_id '#{audio_filename_escaped}'`.strip

  monitor_out_file = "mon_out_#{audio_identifier}.csv"
  if File.exist? monitor_out_file
    puts "#{index}/#{length}, Skipped #{audio_filename}"
    return
  end

  File.open(monitor_out_file, "w") do |f|
    monitor(index,length,audio_filename,ignore_self_match, skip_size,f) 
  end

  puts "#{index}/#{length}, processed #{audio_filename}"
end


def monitor(index,length,audio_filename,ignore_self_match, skip_size,stream)
  audio_filename = File.expand_path(audio_filename)
  audio_filename_escaped =  escape_audio_filename(audio_filename) 


  query_audio_identifer =  `olaf_c name_to_id '#{audio_filename_escaped}'`.strip.to_i

  puts audio_filename_escaped
  puts query_audio_identifer

  tot_duration = audio_file_duration(audio_filename)
  start = 0
  stop = start + skip_size

  while tot_duration > stop do

    with_converted_audio_part(audio_filename_escaped,start,skip_size) do |tempfile|

      stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
      
      stdout.split("\n").each do |line|
        data = line.split(",")
        matching_audio_id = data[4].strip.to_i

        #ignore self matches if requested (for deduplication)
        unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
          stream.puts "#{index}, #{length}_#{start}s, #{File.basename audio_filename}, #{line}\n"
        end

      end
    end
    start = start + skip_size
    stop = start + skip_size
  end
end

def query(index,length,audio_filename,ignore_self_match)
  audio_filename_escaped =  escape_audio_filename(audio_filename)
  return unless audio_filename_escaped

  query_audio_identifer =  `olaf_c name_to_id '#{audio_filename_escaped}'`.strip.to_i

  with_converted_audio(audio_filename_escaped) do |tempfile|
    stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} query \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")

    stdout.split("\n").each do |line|
      data = line.split(",")
      
      matching_audio_id = data[4].to_i

      #ignore self matches if requested (for deduplication)
      unless(ignore_self_match and query_audio_identifer.eql? matching_audio_id)
        puts "#{index}, #{length}, #{File.basename audio_filename}, #{line}\n"
      end
     
    end

    #prints optional debug or error messages
    STDERR.puts stderr unless (stderr == nil or stderr.strip.size == 0)
  end 
end

def with_converted_audio(audio_filename_escaped)
  tempfile = Tempfile.new(["olaf_audio_#{rand(20000)}", '.raw'])
  convert_command = AUDIO_CONVERT_COMMAND
  convert_command = convert_command.gsub("__input__",audio_filename_escaped)
  convert_command = convert_command.gsub("__output__",tempfile.path)
  system convert_command

  yield tempfile

  #remove the temp file afer use
  tempfile.close
  tempfile.unlink
end

def with_converted_audio_files(audio_filenames_escaped)
  tempfiles = Array.new

  audio_filenames_escaped.each do |audio_filename_escaped|
    tempfile = Tempfile.new(["olaf_audio_#{rand(200000)}", '.raw'])
    convert_command = AUDIO_CONVERT_COMMAND
    convert_command = convert_command.gsub("__input__",audio_filename_escaped)
    convert_command = convert_command.gsub("__output__",tempfile.path)
  
    system convert_command

    #puts "Transcoded #{File.basename audio_filename_escaped}"

    tempfiles << tempfile
  end

  yield tempfiles

  tempfiles.each do |tempfile|
    #remove the temp file afer use
    tempfile.close
    tempfile.unlink
  end 
end

def with_converted_audio_part(audio_filename_escaped,start,duration)
  tempfile = Tempfile.new(["olaf_audio_#{rand(20000)}", '.raw'])
  convert_command = AUDIO_CONVERT_COMMAND_WITH_START_DURATION
  convert_command = convert_command.gsub("__input__",audio_filename_escaped)
  convert_command = convert_command.gsub("__output__",tempfile.path)
  convert_command = convert_command.gsub("__start__",start.to_s)
  convert_command = convert_command.gsub("__duration__",duration.to_s)
  
  system convert_command

  yield tempfile

  #remove the temp file afer use
  tempfile.close
  tempfile.unlink
end

def to_raw(index,length,audio_filename)
  audio_filename_escaped = escape_audio_filename(audio_filename)
  return unless audio_filename_escaped
  
  basename = File.basename(audio_filename,File.extname(audio_filename))
  raw_audio_filename = "olaf_audio_#{basename}.raw"
  return if File.exist?(raw_audio_filename)
  
  with_converted_audio(audio_filename_escaped) do |tempfile|
    system("cp '#{tempfile.path}' '#{raw_audio_filename}'")
    puts "#{index}/#{length},#{File.basename audio_filename},#{raw_audio_filename}\n"
  end
end

def to_wav(index,length,raw_audio_filename)
  output_filename = File.basename(raw_audio_filename,File.extname(raw_audio_filename)) + ".wav"
  convert_command = AUDIO_CONVERT_FROM_RAW_COMMAND
  convert_command = convert_command.gsub("__input__",raw_audio_filename)
  convert_command = convert_command.gsub("__output__",output_filename)

  unless File.exist?(output_filename) 
    system(convert_command)
  end
  puts "#{index}/#{length},#{File.basename raw_audio_filename},#{output_filename}\n"
end


def escape_audio_filename(audio_filename)
  begin
    audio_filename.gsub(/(["])/, '\\\\\1')
  rescue
    puts "ERROR, probably invalid byte sequence in UTF-8 in #{audio_filename}"
    return nil
  end
end

def print(index,length,audio_filename)
  audio_filename_escaped = escape_audio_filename(audio_filename)
  return unless audio_filename_escaped
  with_converted_audio(audio_filename_escaped) do |tempfile|
    stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} print \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
    stdout.split("\n").each do |line|
      puts "#{index}/#{length},#{File.expand_path audio_filename},#{line}\n"
    end
  end
end

def store_cached
  cached_files = Dir.glob(File.join(CACHE_FOLDER,"*tdb")).sort
  length = cached_files.size
  cached_files.each_with_index  do |cache_file,index|
    audio_filename = nil
    begin 
      File.open(cache_file, "r") do |f|
        first_line =  f.gets
        audio_filename = first_line.split(",")[1].strip

      end
    rescue
      #could not get the filename: incorrect cache file
      puts "#{index}/#{length} WARNING: #{cache_file} could not be parsed."
    end

    unless audio_filename
      STDERR.puts "#{index}/#{length} No audio filename found in #{cache_file}. Format incorrect?"
      next
    end

    audio_filename_escaped = escape_audio_filename(audio_filename)

    if (SKIP_DUPLICATES && has(audio_filename_escaped))
      puts "#{index}/#{length} #{File.basename audio_filename} SKIPPED: already indexed audio file"
    else
      stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} store_cached \"#{cache_file}\"")
      puts "#{index}/#{length} #{File.basename audio_filename} #{stdout.strip}" 
    end
  end
end

def cache(index,length,audio_filename)
  audio_filename_escaped = escape_audio_filename(audio_filename)
  return unless audio_filename_escaped

  audio_identifier = `olaf_c name_to_id '#{audio_filename_escaped}'`.strip
  cache_file_name = File.join(CACHE_FOLDER,"#{audio_identifier}.tdb")

  if File.exist? cache_file_name
    puts "#{index}/#{length},#{File.basename audio_filename},#{cache_file_name}, SKIPPED: cache file already present"
    return
  end

  if (SKIP_DUPLICATES && has(audio_filename_escaped))
    puts "#{index}/#{length} #{File.basename audio_filename} SKIPPED: already indexed audio file "
    return
  end
  
  with_converted_audio(audio_filename_escaped) do |tempfile|
    Open3.popen3("#{EXECUTABLE_LOCATION} print \"#{tempfile.path}\" \"#{audio_filename_escaped}\"") do |stdin, stdout, stderr, status , thread |
      File.open(cache_file_name,"w") do |cache_file|
        fp_counter = 0
        while line = stdout.gets do 
            cache_file.puts "#{index}/#{length},#{File.expand_path audio_filename},#{line}"
            fp_counter = fp_counter + 1
          end
          puts "#{index}/#{length} , #{File.basename audio_filename} , #{cache_file_name} , #{fp_counter} , #{stderr.gets}"
      end
      
    end
  end
end

def store(index,length,audio_filename)
  audio_filename_escaped = escape_audio_filename(audio_filename)
  return unless audio_filename_escaped

  #Do not store same audio twice
  if(CHECK_INCOMING_AUDIO && audio_file_duration(audio_filename) == 0)
    puts "#{index}/#{length} #{File.basename audio_filename} INVALID audio file? Duration zero."
  elsif (SKIP_DUPLICATES && has(audio_filename_escaped))
    puts "#{index}/#{length} #{File.basename audio_filename} SKIP: already stored audio "
  else
    with_converted_audio(audio_filename_escaped) do |tempfile|
      stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} store \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
      puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
    end
  end
end

def microphone
  argument = ""
  puts "#{MIC_INPUT} | #{EXECUTABLE_LOCATION} query"
  Open3.popen3("#{MIC_INPUT} | #{EXECUTABLE_LOCATION} query") do |stdin, stdout, stderr, wait_thr|
    pid = wait_thr.pid

    #Thread.new do 
    #  sleep(1)
      #Process.kill("SIGALRM", pid)
    #end

    #Thread.new do
    #  sleep(5)
      #Process.kill("SIGINFO", pid)
    #end
    
    Thread.new do
     stdout.each {|l| puts l }
    end

    Thread.new do
     stderr.each {|l| puts l }
    end

    wait_thr.value
  end
end

def clear(arguments)
  force = arguments.include? "-f"
  delete_db = force
  delete_cache = force

  if !force
    puts "Proceed with deleting the olaf db (#{"%d MB" % folder_size(DB_FOLDER)} #{DB_FOLDER})? (yes/no)"
    confirmation = STDIN.gets.chomp
    if confirmation == "yes"
      delete_db = true
    else
      puts "Nothing deleted"
    end

    puts "Proceed with deleting the olaf cache (#{"%d MB" % folder_size(CACHE_FOLDER)} #{CACHE_FOLDER})? (yes/no)"
    confirmation = STDIN.gets.chomp
    if confirmation == "yes"
      delete_cache = true
    else
      puts "Operation cancelled."
    end
  end

  if(delete_db)
    puts "Clear the database folder."
    FileUtils.rm Dir.glob("#{DB_FOLDER}/*") if File.exist? DB_FOLDER
  end

  if(delete_cache)
    puts "Clear the cache folder"
    FileUtils.rm Dir.glob("#{CACHE_FOLDER}/*") if File.exist? CACHE_FOLDER
  end
end

def delete(index,length,audio_filename)

  audio_filename_escaped = escape_audio_filename(audio_filename)
  return unless audio_filename_escaped
  
  #Do not store same audio twice
  with_converted_audio(audio_filename_escaped) do |tempfile|
    stdout, stderr, status = Open3.capture3("#{EXECUTABLE_LOCATION} delete \"#{tempfile.path}\" \"#{audio_filename_escaped}\"")
    puts "#{index}/#{length} #{File.basename audio_filename} #{stderr.strip}" 
  end
end

#create the db folders unless it exist
FileUtils.mkdir_p DB_FOLDER unless File.exist?(DB_FOLDER)
FileUtils.mkdir_p CACHE_FOLDER unless File.exist?(CACHE_FOLDER)

command  = ARGV[0]

audio_files = Array.new

threads = 1
fragmented = false
allow_identity_match = true 

#finds and verifies threads argument
arg_index = ARGV.find_index("--threads")
if arg_index
  threads_str = ARGV[arg_index + 1].strip
  if threads_str && threads_str =~ /(\d+)/
    threads = threads_str.to_i
  else
    STDERR.puts "Expected a numeric argument for '--threads': 'olaf cache files --threads 8'"
    exit(-9)
  end
  #delete --threads and numeric argument from list
  ARGV.delete_at(arg_index)
  ARGV.delete_at(arg_index)
end

if threads > 1 and ! require("threach")
  STDERR.puts "The gem 'threach' is needed for parralel execution. Install with"
  STDERR.puts "gem install threach"
  exit(-10)
end

arg_index = ARGV.find_index("--no-identiy-match")
if arg_index
  allow_identity_match = false
  #delete --fragmented from argument list
  ARGV.delete_at(arg_index)
end

arg_index = ARGV.find_index("--fragmented")
if arg_index
  fragmented = true
  #delete --fragmented from argument list
  ARGV.delete_at(arg_index)
end

#this method wraps threach but only if it is needed (threads > 1)
def threach_with_index(array,threads)
  if threads == 1
    array.each_with_index do |element, indx|
      yield element, indx
    end
  else
    require 'threach'
    array.threach(threads, :each_with_index) do |element, indx|
      yield element, indx
    end
  end
end

commands = {
  "stats" => {
    :description => "Print statistics about the index.
    ",
    :help => "",
    :needs_audio_files => false,
    :lambda => -> { system("#{EXECUTABLE_LOCATION} stats") }
  },
  "store" => {
    :description => "Extracts and stores fingerprints into an index.
    ",
    :help => "audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      audio_files.each_with_index do |audio_file, index|
        store(index+1,audio_files.length,audio_file)
      end
    end
  },
  "to_raw" => {
    :description => "Converts audio to the RAW format olaf understands. Mainly for debugging.
    \t--threads n\t The number of threads to use.
    ",
    :help => "[--threads n] audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      threach_with_index(audio_files,threads) do |audio_file, index|
        to_raw(index+1,audio_files.length,audio_file)
      end
    end
  },
  "to_wav" => {
    :description => "Converts audio from the RAW format olaf understands to wav. 
    \t--threads n\t The number of threads to use.
    ",
    :help => "[--threads n] audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      threach_with_index(audio_files,threads) do |audio_file, index|
        to_wav(index+1,audio_files.length,audio_file)
      end
    end
  },
  "mic" => {
    :description => "Captures audio from the microphone and matches incoming audio with the index.
    ",
    :help => "",
    :needs_audio_files => false,
    :lambda => -> do
      microphone
    end
  },
  "delete" => {
    :description => "Deletes audio files from the index.
    ",
    :help => "audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      audio_files.each_with_index do |audio_file, index|
        delete(index+1, audio_files.length, audio_file)
      end
    end
  },
  "print" => {
    :description => "Print fingerprint info to STDOUT.
    ",
    :help => "audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      audio_files.each_with_index do |audio_file, index|
        print(index+1, audio_files.length, audio_file)
      end
    end
  },
  "query" => {
    :description => "Extracts fingerprints from audio, matches them with the index and report matches.
    \t\t--threads n\t The number of threads to use.
    \t\t--fragmented\t If present it does not match the full query all at once \n\t\t\tbut chops the query into #{MONITOR_LENGTH_IN_SECONDS}s fragments and matches each fragment.
    \t\t--no-identity-match n\t If present identiy matches are not reported: \n\t\t\twhen a query is present in the index and it matches with itself it is not reported.
    ",
    :help => "[--fragmented] [--threads x] audio_files...",
    :needs_audio_files => true,
    :lambda => -> do

       threach_with_index(audio_files,threads) do |audio_file, index|
        if fragmented
          monitor(index+1, audio_files.length, audio_file, !allow_identity_match, MONITOR_LENGTH_IN_SECONDS, STDOUT)
        else
          query(index+1, audio_files.length, audio_file, !allow_identity_match)
        end
      end

    end
  },
  "cache" => {
    :description => "Extracts fingerprints and caches the fingerprints in a text file.
    \tThis is used to speed up fingerprint extraction by using multiple CPU cores.
    \t\t--threads n\t The number of threads to use.
    ",
    :help => "[--threads x] audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      if threads == 1
        puts "Warning: only using a single thread. Speed up with e.g. with --threads 8"
      end
      threach_with_index(audio_files,threads) do |audio_file, index|
          cache(index+1, audio_files.length, audio_file)
      end
    end
  },
  "store_cached" => {
    :description => "Stores fingerprint cached in text files.
    \tAfter caching fingerprints in text files (on multiple cores) with 'olaf cache audio_files...' use store_cached
    \tto index the fingerprints in a datastore",
    :help => "",
    :needs_audio_files => false,
    :lambda => -> { store_cached }
  },
  "dedup" => {
    :description => "Deduplicates audio files: First all files are stored in the index. 
    \tThen all files are matched with the index.
    \tIdentity matches are not reported.
    \t\t--threads n\t The number of threads to use.
    \t\t--fragmented\t If present it does not match the full query all at once \n\t\t\tbut chops the query into #{MONITOR_LENGTH_IN_SECONDS}s fragments and matches each fragment.
    ",

    :help => "[--fragmented] [--threads x] audio_files...",
    :needs_audio_files => true,
    :lambda => -> do
      audio_files.each_with_index do |audio_file, index|
        store(index+1, audio_files.length, audio_file)
      end

      threach_with_index(audio_files,threads) do |audio_file, index|
        if fragmented
          monitor(index+1, audio_files.length, audio_file, true, MONITOR_LENGTH_IN_SECONDS, STDOUT)
        else
          query(index+1, audio_files.length, audio_file, true)
        end
      end
    end
  },
  "clear" => {
    :description => "Deletes the database and cached files. \n\t -f to delete without confirmation.",
    :help => "[-f]",
    :needs_audio_files => false,
    :lambda => -> { clear(ARGV) }
  },

}

def print_help(commands)
  date_stamp = File.stat(EXECUTABLE_LOCATION).mtime.strftime("%Y.%m.%d")

  puts "Olaf #{date_stamp} - Overly Lightweight Audio Fingerprinting" 
  "No such command, the following commands are valid:"
  commands.keys.sort.each do |key|
    value = commands[key]
    puts
    puts "#{key}\t#{value[:description]}"
    puts "\tolaf #{key} #{value[:help]}"
  end
end

#command not found
if (command.nil? or ! commands.keys.include? command)
  print_help(commands)
  exit(-10)
end

cmd = commands[command]

#If the command needs audio files, make a list
if cmd[:needs_audio_files]
  ARGV.shift
  ARGV.each do |audio_argument|
    audio_files = audio_file_list(audio_argument,audio_files)
  end

  if audio_files.size == 0
    puts "This command needs audio files, none are found."
    puts "olaf #{command} #{cmd[:help]}"
    exit(-11)
  end
end

cmd[:lambda].call
