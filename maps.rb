#!/usr/bin/env ruby

require 'rubygems'
require 'bundler/setup'
require 'active_support/all'
require 'colorize'
require 'facets'

require 'pry'
require 'pry-byebug'

require 'mini_magick'

TILE_SIZE = 512 # px
PRINT_WIDTH = 1.0 # m
PRINT_ZOOM = 15
# CROP = {x: 15, y: 10, width: 4, height: 2, zoom: 5}.freeze # tiles # Europe
# CROP = {x: 0, y: 2, width: 16, height: 11, zoom: 4}.freeze # tiles # World
CROP = {x: 2178, y: 1420, width: 3, height: 3, zoom: 12}.freeze # tiles # Munich

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

def tile_url(tile)
  "https://mt0.google.com/vt?lyrs=p&scale=#{TILE_SIZE / 256}&x=#{tile[:x]}&y=#{tile[:y]}&z=#{tile[:zoom]}&hl=loc"
end

def tile_path(tile)
  base_path = File.dirname __FILE__
  dir_path = "#{base_path}/tiles/#{tile[:zoom]}"
  file_path = "#{dir_path}/#{tile[:x]}_#{tile[:y]}.png"

  unless File.exist? file_path
    Dir.mkdir dir_path unless Dir.exist? dir_path
    `wget -q -O #{file_path} "#{tile_url(tile)}"`
  end

  file_path
end

def imgcat(path)
  puts `~/.iterm2/imgcat "#{path}"`
end

def concat_tiles(tile_paths, width, height, output_path)
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
  preview_width = 1000 # px
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

# lat, lon, zoom = 48.1351, 11.5820, 8 #41.850, -87.650, 3
# _, _, x, y = tile_coordinates(lat, lon, zoom)
# path = tile_path(lat, lon, zoom)

# MiniMagick::Image.new(path) do |b|
#   b.fill 'red'
#   b.stroke 'black'
#   b.draw "circle #{x},#{y} #{x + 10},#{y}"
# end

#imgcat path

#p tile_path($print_crop)

preview
