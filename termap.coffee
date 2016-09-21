###
  termap - Terminal Map Viewer
  by Michael Strassburger <codepoet@cpan.org>
###

keypress = require 'keypress'
TermMouse = require 'term-mouse'
x256 = require 'x256'
Protobuf = require 'pbf'
VectorTile = require('vector-tile').VectorTile
fs = require 'fs'
zlib = require 'zlib'

mercator = new (require('sphericalmercator'))()
triangulator = new (require('pnltri')).Triangulator()

Canvas = require __dirname+'/src/Canvas'
LabelBuffer = require __dirname+'/src/LabelBuffer'
Styler = require __dirname+'/src/Styler'
utils = require __dirname+'/src/utils'

class Termap
  config:
    language: 'de'
    styleFile: __dirname+"/styles/bright.json"

    fillPolygons: true
    zoomStep: 0.4

    drawOrder: ["admin", "water", "building", "road", "poi_label", "place_label", "housenum_label"]

    icons:
      car: "🚗"
      school: "S" #{}"🏫"
      marker: "⭐"
      'art-gallery': "A" #"🎨"
      attraction: "❕"
      stadium: "🏈"
      toilet: "🚽"
      cafe: "☕"
      laundry: "👚"
      bus: "🚌"
      restaurant: "R" #🍛"
      lodging: "B" #🛏"
      'fire-station': "🚒"
      shop: "🛍"
      pharmacy: "💊"
      beer: "H" #"🍺"
      cinema: "C" #"🎦"

    layers:
      housenum_label:
        minZoom: 2
        color: 8
      building:
        minZoom: 3.8
        color: 8

      place_label:
        color: "yellow"

      poi_label:
        minZoom: 3
        color: "yellow"

      road:
        color: 15

      landuse:
        color: "green"
      water:
        color: "blue"
      admin:
        color: "red"

  mouse: null
  width: null
  height: null
  canvas: null

  styler: null
  isDrawing: false
  lastDrawAt: 0

  mousePosition: [0, 0]
  mouseDragging: false

  center:
    lat: 49.019855
    lng: 12.096956

  zoom: 2
  view: [0, 0]

  scale: 4

  constructor: ->
    @_initControls()
    @_initCanvas()

    @_onResize =>
      @_initCanvas()
      @_draw()

  _initControls: ->
    keypress process.stdin
    process.stdin.setRawMode true
    process.stdin.resume()

    process.stdin.on 'keypress', (ch, key) => @_onKey key

    @mouse = TermMouse()
    @mouse.start()

    @mouse.on 'click', (event) => @_onClick event
    @mouse.on 'scroll', (event) => @_onMouseScroll event
    @mouse.on 'move', (event) => @_onMouseMove event

  _initCanvas: ->
    @width = Math.floor((process.stdout.columns-1)/2)*2*2
    @height = Math.ceil(process.stdout.rows/4)*4*4
    @canvas = new Canvas @width, @height

    unless @lastDrawAt
      @zoom = Math.log(4096/@width)/Math.LN2

    @labelBuffer = new LabelBuffer()
    @styler = new Styler @config.styleFile

  _onResize: (cb) ->
    process.stdout.on 'resize', cb

  _onClick: (event) ->
    if @mouseDragging and event.button is "left"
      @view[0] -= (@mouseDragging.x-@mousePosition.x)*2
      @view[1] -= (@mouseDragging.y-@mousePosition.y)*4
      @_draw()

      @mouseDragging = false

  _onMouseScroll: (event) ->
    # TODO: handle .x/y for directed zoom
    @zoomBy @config.zoomStep * if event.button is "up" then 1 else -1
    @_draw()

  _onMouseMove: (event) ->
    # only continue if x/y are valid
    return unless event.x <= process.stdout.columns and event.y <= process.stdout.rows

    # start dragging
    if not @mouseDragging and event.button is "left"
      @mouseDragging = x: event.x, y: event.y

    # update internal mouse tracker
    @mousePosition = x: event.x, y: event.y

  _onKey: (key) ->
    # check if the pressed key is configured
    draw = switch key?.name
      when "q"
        process.exit 0

      when "z" then @zoomBy @config.zoomStep
      when "a" then @zoomBy -@config.zoomStep
      when "left" then @view[0] += 5
      when "right" then @view[0] -= 5
      when "up" then @view[1]+= 5
      when "down" then @view[1]-= 5

      else
        false

    if draw
      @_draw()
    # else
    #   # display debug info for unhandled keys
    #   @notify JSON.stringify key

  _parseTile: (buffer) ->
    # extract, decode and parse a given tile buffer
    new VectorTile new Protobuf zlib.gunzipSync data

  _getFeatures: (tile) ->
    features = {}
    for name,layer of tile.layers
      continue unless @config.layers[name]

      features[name] = for i in [0...layer.length]
        feature = layer.feature i
        type = [undefined, "Point", "LineString", "Polygon"][feature.type]

        properties = feature.properties
        properties.$type = type

        id: feature.id
        type: type
        properties: properties
        points: feature.loadGeometry()

    features

  _draw: ->
    return if @isDrawing
    @isDrawing = true
    @lastDrawAt = Date.now()

    # if color = @styler.styleById['background']?.paint['background-color']
    #   @canvas.strokeStyle = x256 utils.hex2rgb(color)...
    #   @canvas.fillRect 0, 0, @width, @height
    # else
    @canvas.clearRect 0, 0, @width, @height

    @canvas.save()
    @canvas.translate @view[0], @view[1]

    @labelBuffer.clear()

    drawn = @_drawLayers()

    @canvas.restore()

    @_write @canvas._canvas.frame()
    @_write @_getFooter()

    @isDrawing = false

  _drawLayers: ->
    drawn = []
    for layer in @config.drawOrder
      scale = Math.pow 2, @zoom
      continue unless @features?[layer]

      if @config.layers[layer].minZoom and @zoom > @config.layers[layer].minZoom
        continue

      @canvas.strokeStyle = @canvas.fillStyle = @config.layers[layer].color

      for feature in @features[layer]
        if @_drawFeature layer, feature, scale
          drawn.push feature

    drawn

  _drawFeature: (layer, feature, scale) ->
    # TODO: this is ugly :) need to be fixed @style
    return false if layer is 'road' and feature.type is "Polygon"
    feature.type = "LineString" if layer is "building"

    toDraw = []
    for idx, points of feature.points
      visible = false

      projectedPoints = for point in points
        projectedPoint =
          x: point.x/scale
          y: point.y/scale

        visible = true if not visible and @_isOnScreen projectedPoint
        projectedPoint

      if idx is 0 and not visible
        return false

      continue unless visible
      toDraw.push projectedPoints

    if style = @styler.getStyleFor layer, feature, 14
      color = style.paint['line-color'] or style.paint['fill-color']

      # TODO: zoom calculation todo for perfect styling
      if color instanceof Object
        color = color.stops[0][1]

      @canvas.fillStyle = @canvas.strokeStyle = x256 utils.hex2rgb color
    else
      @canvas.strokeStyle = @canvas.fillStyle = @config.layers[layer].color

    switch feature.type
      when "LineString"
        @_drawWithLines points for points in toDraw
        true

      when "Polygon"
        unless @config.fillPolygons and @_drawWithTriangles toDraw
          @_drawWithLines points for points in toDraw
        true

      when "Point"
        text = feature.properties["name_"+@config.language] or
          feature.properties["name"] or
          feature.properties.house_num or
          @config.icons[feature.properties.maki] or
          "◉"

        wasDrawn = false
        # TODO: check in definition if points can actually own multiple geometries
        for points in toDraw
          for point in points
            if @labelBuffer.writeIfPossible text, point.x, point.y
              @canvas.fillText text, point.x, point.y
              wasDrawn = true

        wasDrawn

  _drawWithTriangles: (points) ->
    try
      triangles = triangulator.triangulate_polygon points
    catch
      return false

    return false unless triangles.length

    # TODO: triangles are returned as vertex references to a flattened input.
    #       optimize it!

    arr = points.reduce (a, b) -> a.concat b
    for triangle in triangles
      try
        @canvas.fillTriangle arr[triangle[0]], arr[triangle[1]], arr[triangle[2]]
      catch
        return false
    true

  _drawWithLines: (points) ->
    @canvas.beginPath()
    first = points.shift()
    @canvas.moveTo first.x, first.y
    @canvas.lineTo point.x, point.y for point in points
    @canvas.stroke()

  _isOnScreen: (point) ->
    point.x+@view[0]>=4 and
    point.x+@view[0]<@width-4 and
    point.y+@view[1]>=0 and
    point.y+@view[1]<@height

  _write: (text) ->
    process.stdout.write text

  _getBBox: ->
    [x, y] = mercator.forward [@center.lng, @center.lat]
    width = @width * Math.pow(2, @zoom)
    height = @height * Math.pow(2, @zoom)

    mercator.inverse([x - width/2, y + width/2]).concat mercator.inverse([x + width/2, y - width/2])

  _getFooter: ->
    "center: [#{utils.digits @center.lat, 2}, #{utils.digits @center.lng, 2}] zoom: #{utils.digits @zoom, 2}"
    # bbox: [#{@_getBBox().map((z) -> utils.digits(z, 2)).join(',')}]"

  notify: (text) ->
    return if @isDrawing
    @_write "\r\x1B[K#{@_getFooter()} #{text}"

  zoomBy: (step) ->
    return unless @scale+step > 0

    before = @scale
    @scale += step
    @zoom += step

    @view[0] = @view[0]*before/@scale + if step > 0 then 8 else -8
    @view[1] = @view[1]*before/@scale + if step > 0 then 8 else -8

termap = new Termap()

# TODO: abstracing this class, create loader class
data = fs.readFileSync __dirname+"/tiles/regensburg.pbf.gz"
termap.features = termap._getFeatures termap._parseTile data
termap._draw()
