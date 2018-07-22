#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'active_support/all'
require 'colorize'
require 'facets'

require 'pry'
require 'pry-byebug'

require 'mini_magick'
require 'prawn'
require 'prawn/measurement_extensions'

require 'parallel'

TILE_SIZE = 512 # px
PRINT_WIDTH = 5.0 # m
PRINT_ZOOM = 7
# CROP = {x: 15, y: 10, width: 4, height: 2, zoom: 5}.freeze # tiles # Europe
CROP = {x: 0, y: 5, width: 32, height: 20, zoom: 5, key: 'world'}.freeze # tiles # World
# CROP = {x: 2178, y: 1420, width: 3, height: 3, zoom: 12, key: 'munich'}.freeze # tiles # Munich
# CROP = {x: 34871, y: 22738, width: 6, height: 6, zoom: 16, key: 'uni'}.freeze # tiles # Uni
# CROP = {x: 34871, y: 22738, width: 6, height: 6, zoom: 16, key: 'uni'}.freeze # tiles # Uni

# h = roads only
# m = standard roadmap
# p = Terrain mit Beschriftungen (Ländergrenzen, Ländernamen, etc.).
# r = somehow altered roadmap
# s = satellite only
# t = terrain only
# y = hybrid
# watercolor = Wasserfarbe
# LYRS = 'watercolor_google_overlay'.freeze
LYRS = 'p'

puts 'WARNING: PRINT_ZOOM smaller than CROP zoom' if PRINT_ZOOM < CROP[:zoom]

$pcm = 2**(PRINT_ZOOM - CROP[:zoom]) # print_crop_multiplier
$print_crop = {x: CROP[:x] * $pcm, y: CROP[:y] * $pcm, width: CROP[:width] * $pcm, height: CROP[:height] * $pcm,
    zoom: PRINT_ZOOM}

$print_height = (PRINT_WIDTH / ($print_crop[:width])) * $print_crop[:height]
$print_tile_size = PRINT_WIDTH / ($print_crop[:width]) # m
$print_dpi = (TILE_SIZE / ($print_tile_size)) * 0.0254 # dpi (1 in/m = 0.0254)
$tile_count = $print_crop[:width] * $print_crop[:height]

puts "Print size: #{PRINT_WIDTH}m x #{$print_height}m"
puts "Print tiles: #{$print_crop[:width]} x #{$print_crop[:height]} (zoom #{$print_crop[:zoom]}, #{$tile_count} total)"
puts "Print resolution: #{$print_dpi} dpi"

def geo_to_tile(geo, zoom)
  scale = 1 << zoom

  world_coordinate = project geo
  pixel_coordinate = {x: (world_coordinate[:x] * scale).floor, y: (world_coordinate[:y] * scale).floor}
  tile_coordinate = {x: (world_coordinate[:x] * scale / TILE_SIZE).floor,
      y: (world_coordinate[:x] * scale / TILE_SIZE).floor}

  {x: tile_coordinate[:x], y: tile_coordinate[:y], zoom: zoom,
      x_px_remainder: pixel_coordinate[:x] % TILE_SIZE, y_px_remainder: pixel_coordinate[1] % TILE_SIZE}
end

def project(geo)
  siny = Math.sin(geo[:lat] * Math::PI / 180)

  # Truncating to 0.9999 effectively limits latitude to 89.189. This is
  # about a third of a tile past the edge of the world tile.
  siny = [[siny, -0.9999].max, 0.9999].min

  {x: TILE_SIZE * (0.5 + geo[:lon] / 360), y: TILE_SIZE * (0.5 - Math.log((1 + siny) / (1 - siny)) / (4 * Math::PI))}
end

def tile_to_geo(tile)
  n = 2.0 ** tile[:zoom]

  lon_deg = tile[:x] / n * 360.0 - 180.0
  lat_rad = Math::atan(Math::sinh(Math::PI * (1 - 2 * tile[:y] / n)))
  lat_deg = 180.0 * (lat_rad / Math::PI)

  {lat: lat_deg, lon: lon_deg}
end

def tile_url(tile)
  case LYRS
  when 'watercolor'
    "http://c.tile.stamen.com/watercolor/#{tile[:zoom]}/#{tile[:x]}/#{tile[:y]}.jpg"
  when 'google_overlay'
    # poi.business  33

    # poi.attraction  37
    # poi.government  34
    # poi.medical  36
    # poi.park  40
    # poi.place_of_worship  38
    # poi.school  35
    # poi.sports_complex  39

    # https://stackoverflow.com/questions/29692737/customizing-google-map-tile-server-url

    "https://mts0.google.com/vt/lyrs=h&hl=de&src=app&x=#{tile[:x]}&y=#{tile[:y]}&z=#{tile[:zoom]}&scale=#{TILE_SIZE / 256}&apistyle=s.t:37|s.e:l|p.v:off;s.t:34|s.e:l|p.v:off;s.t:36|s.e:l|p.v:off;s.t:40|s.e:l|p.v:off;s.t:38|s.e:l|p.v:off;s.t:35|s.e:l|p.v:off;s.t:39|s.e:l|p.v:off"
  else
    "https://mt0.google.com/vt?lyrs=#{LYRS}&scale=#{TILE_SIZE / 256}&x=#{tile[:x]}&y=#{tile[:y]}&z=#{tile[:zoom]}&hl=loc"
  end
end

def tile_path(tile)
  base_path = File.dirname __FILE__
  dir_path = "#{base_path}/tiles/#{tile[:zoom]}"
  lyrs_path = "#{dir_path}/#{LYRS}"
  file_path = "#{lyrs_path}/#{tile[:x]}_#{tile[:y]}.png"

  unless File.exist? file_path
    puts "Downloading #{tile[:x]}, #{tile[:y]}, #{tile[:zoom]}"
    Dir.mkdir dir_path unless Dir.exist? dir_path
    Dir.mkdir lyrs_path unless Dir.exist? lyrs_path

    `touch #{file_path}`

    # proxy = '127.0.0.1:5566'
    proxy = nil

    if proxy.present?
      cmd = "wget -e use_proxy=yes -e http_proxy=127.0.0.1:5566 -e https_proxy=127.0.0.1:5566 -q -O #{file_path} \"#{tile_url(tile)}\""
      # puts cmd
      `#{cmd}`
    else
      `wget -q -O #{file_path} "#{tile_url(tile)}"`
    end

    if File.size(file_path).zero?
      File.delete file_path
      puts 'Google blocked ip'
      # throw 'Google blocked ip'
    end
  end

  file_path
end

def tile_from_path(path)
  match = path.match /((\A|\/)(?<zoom>\d+)\/)?(?<x>\d+)_(?<y>\d+).png\z/
  {x: match[:x].to_i, y: match[:y].to_i, zoom: match[:zoom].try(:to_i)}
end

def imgcat(path)
  puts `~/.iterm2/imgcat "#{path}"`
end

def concat_tiles(tile_paths, width, height, output_path)
  dir_path = File.expand_path("..", output_path)
  Dir.mkdir dir_path unless Dir.exist? dir_path

  # MiniMagick.logger.level = Logger::DEBUG
  montage = MiniMagick::Tool::Montage.new
  tile_paths.each { |tile| montage << tile }
  montage << '-mode'
  montage << 'Concatenate'
  montage << '-tile'
  montage << "#{width}x#{height}"
  montage << output_path
  montage.call
end

def preview_crop(width)
  zoom_crops = [$print_crop.merge({
    x2: $print_crop[:x] + $print_crop[:width],
    y2: $print_crop[:y] + $print_crop[:height],
    cut_left: 0,
    cut_right: 0,
    cut_top: 0,
    cut_bottom: 0
  })]

  ($print_crop[:zoom] - 1).downto(0) do |zoom|
    last_crop = zoom_crops[-1]

    cur_crop = {
      x: (last_crop[:x] / 2.0).floor,
      x2: (last_crop[:x2] / 2.0).ceil,
      y: (last_crop[:y] / 2.0).floor,
      y2: (last_crop[:y2] / 2.0).ceil,
      cut_left: (last_crop[:cut_left] / 2.0) + ((last_crop[:x] / 2.0) % 1),
      cut_right: (last_crop[:cut_right] / 2.0) + ((last_crop[:x2] / 2.0) % 1),
      cut_top: (last_crop[:cut_top] / 2.0) + ((last_crop[:y] / 2.0) % 1),
      cut_bottom: (last_crop[:cut_bottom] / 2.0) + ((last_crop[:y2] / 2.0) % 1),
      zoom: zoom
    }
    cur_crop[:width] = cur_crop[:x2] - cur_crop[:x]
    cur_crop[:height] = cur_crop[:y2] - cur_crop[:y]

    zoom_crops << cur_crop

    break if cur_crop[:width] * TILE_SIZE < width
  end

  zoom_crops[-1]
end

def preview
  preview_width = 1200 # px
  preview_path = "#{File.dirname __FILE__}/preview.png"
  crop = preview_crop preview_width

  tiles = []
  (crop[:y]...crop[:y2]).each do |y|
    (crop[:x]...crop[:x2]).each do |x|
      tiles << tile_path(x: x, y: y, zoom: crop[:zoom])
    end
  end

  concat_tiles tiles, crop[:width], crop[:height], preview_path

  crop_left = crop[:cut_left] * TILE_SIZE
  crop_right = crop[:cut_right] * TILE_SIZE
  crop_top = crop[:cut_top] * TILE_SIZE
  crop_bottom = crop[:cut_bottom] * TILE_SIZE
  width = crop[:width] * TILE_SIZE
  height = crop[:height] * TILE_SIZE

  MiniMagick::Image.new(preview_path) do |b|
    b.crop "#{width - crop_left - crop_right}x#{height - crop_top - crop_bottom}+#{crop_left}+#{crop_top}"
  end

  imgcat preview_path
end

def donwload_tiles(crop)
  (0...crop[:height]).each do |y|
    (0...crop[:width]).each do |x|
      tile_path x: crop[:x] + x, y: crop[:y] + y, zoom: crop[:zoom]
    end
  end
end

def make_prints
  paper_physical_size = {width: 0.18, height: 0.28 } # m

  paper_size = {width: ((paper_physical_size[:width] / ($print_tile_size)) * TILE_SIZE).floor,
      height: ((paper_physical_size[:height] / ($print_tile_size)) * TILE_SIZE).floor} # px

  total_size = {width: $print_crop[:width] * TILE_SIZE, height: $print_crop[:height] * TILE_SIZE}

  puts '---'
  puts "Paper width: #{paper_size[:width]} px"
  puts "Total width: #{total_size[:width]} px"

  (0...total_size[:height]).step(paper_size[:height]).each_with_index do |paper_y1, paper_y_i|
    paper_y2 = [paper_y1 + paper_size[:height], total_size[:height]].min

    tile_y_min, tile_y_max = 0
    crop_top, crop_bottom = 0
    (0...total_size[:height]).step(TILE_SIZE).each_with_index do |tile_y1, tile_y_i|
      tile_y2 = tile_y1 + TILE_SIZE

      if tile_y1 <= paper_y1 && tile_y2 >= paper_y1
        tile_y_min = tile_y_i
        crop_top = paper_y1 - tile_y1
      end

      if tile_y1 <  paper_y2 && tile_y2 >= paper_y2
        tile_y_max = tile_y_i
        crop_bottom = tile_y2 - paper_y2
      end
    end

    (0...total_size[:width]).step(paper_size[:width]).each_with_index do |paper_x1, paper_x_i|
      paper_x2 = [paper_x1 + paper_size[:width], total_size[:width]].min

      tile_x_min, tile_x_max = 0
      crop_left, crop_right = 0
      (0...total_size[:width]).step(TILE_SIZE).each_with_index do |tile_x1, tile_x_i|
        tile_x2 = tile_x1 + TILE_SIZE

        if tile_x1 <= paper_x1 && tile_x2 >= paper_x1
          tile_x_min = tile_x_i
          crop_left = paper_x1 - tile_x1
        end

        if tile_x1 <  paper_x2 && tile_x2 >= paper_x2
          tile_x_max = tile_x_i
          crop_right = tile_x2 - paper_x2
        end
      end

      tiles = []
      (tile_y_min..tile_y_max).each do |tile_y|
        (tile_x_min..tile_x_max).each do |tile_x|
          tiles << tile_path(x: $print_crop[:x] + tile_x, y: $print_crop[:y] + tile_y, zoom: $print_crop[:zoom])
        end
      end

      render_path = "#{File.dirname __FILE__}/renders/#{CROP[:key]}/#{paper_x_i}_#{paper_y_i}.png"

      concat_tiles(tiles, tile_x_max - tile_x_min + 1, tile_y_max - tile_y_min + 1, render_path)

      MiniMagick::Image.new(render_path) do |b|
        b.crop "#{paper_x2 - paper_x1}x#{paper_y2 - paper_y1}+#{crop_left}+#{crop_top}"
      end

      render_physical_width = ((paper_x2 - paper_x1) / paper_size[:width].to_f) * paper_physical_size[:width] # m
      pdf = Prawn::Document.new(page_size: 'A4')
      pdf.image render_path, at: [0.cm, 28.cm - 5.mm], width: render_physical_width.m
      pdf.render_file("prints/#{CROP[:key]}/#{paper_x_i}_#{paper_y_i}.pdf")
    end

  end
end

# Preview
# preview

# Download
# Parallel.each(1..5, in_processes: 5) do
#   Parallel.each(1..10, in_threads: 10) do
#     donwload_tiles $print_crop
#   end
# end

# Make prints
# make_prints

