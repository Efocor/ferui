#.............................................................................................................
#comentario: Reproductor de música con interfaz gráfica en Ruby
#proyecto: Hecho por Felipe Correa / FECORO.
#prueba para reproducir .mp3 y .wav, ambos formatos nativos de Windows.

require 'gtk3'
require 'win32/sound'
require 'win32ole'
require 'pathname'
require 'json'
require 'fileutils'

class Song
  attr_reader :path, :title, :artist, :album, :duration, :format
  
  def initialize(path_archivo)
    @path = path_archivo
    @format = File.extname(path_archivo).downcase[1..]
    sacar_info_basic
  end

  private

  def sacar_info_basic
    filename = File.basename(@path, ".*")
    if filename =~ /^(.+) - (.+)$/
      @artist = $1.strip
      @title = $2.strip
    else
      @artist = "Desconocido"
      @title = filename
    end
    @album = "Desconocido"
    estima_dura
  end

  def estima_dura
    file_size = File.size(@path)
    case @format
    when 'mp3'
      @duration = file_size / 16_000
    when 'wav'
      @duration = file_size / 176_400
    else
      @duration = file_size / 16_000
    end
  end
end

class MusicPlayer
  SUPPORTED_FORMATS = %w[mp3 wav]
  CONFIG_FILE = File.join(Dir.home, '.music_player_config.json')

  def initialize
    @window = Gtk::Window.new("Reproductor de Música")
    @window.set_default_size(800, 600)
    @window.set_border_width(10)

    @current_song = nil
    @is_playing = false
    @playlist = []
    @current_index = 0
    @volume = 1.0
    @repeat_mode = :none
    @shuffle_mode = false
    @last_folder = nil
    @progress_updater = nil
    @start_time = nil

    carga_configcasode
    creaui
    shortkutstecladin
    setupdelautosave

    @window.signal_connect("destroy") do
      para_playback
      guarda_config
      Gtk.main_quit
    end

    @window.show_all
  end

  private

  def creaui
    main_box = Gtk::Box.new(:vertical, 10)
    @window.add(main_box)

    crearbarme(main_box)
    creapaneltop(main_box)
    vistaplaylist(main_box)
    sehacepanelinfo(main_box)
    creacontrolplayback(main_box)
    barradeeprogreso(main_box)
    creapanelbajo(main_box)
  end

  def infopanelupda ()
    @current_song_label.text = @current_song.title
    @artist_label.text = "Artista: #{@current_song.artist}"
    @album_label.text = "Álbum: #{@current_song.album}"
    @format_label.text = "Formato: #{@current_song.format}"
    end

  def crearbarme(main_box)
    menu_bar = Gtk::MenuBar.new

    file_menu = Gtk::Menu.new
    file_item = Gtk::MenuItem.new(label: "Archivo")
    file_item.set_submenu(file_menu)

    open_item = Gtk::MenuItem.new(label: "Abrir Archivo")
    open_item.signal_connect("activate") { abro_archv }
    
    check_carpeta_item = Gtk::MenuItem.new(label: "Abrir Carpeta")
    check_carpeta_item.signal_connect("activate") { check_carpeta }
    
    salvate_playlist_item = Gtk::MenuItem.new(label: "Guardar Lista")
    salvate_playlist_item.signal_connect("activate") { salvate_playlist }
    
    carga_playlist_item = Gtk::MenuItem.new(label: "Cargar Lista")
    carga_playlist_item.signal_connect("activate") { carga_playlist }
    
    exit_item = Gtk::MenuItem.new(label: "Salir")
    exit_item.signal_connect("activate") { Gtk.main_quit }

    file_menu.append(open_item)
    file_menu.append(check_carpeta_item)
    file_menu.append(Gtk::SeparatorMenuItem.new)
    file_menu.append(salvate_playlist_item)
    file_menu.append(carga_playlist_item)
    file_menu.append(Gtk::SeparatorMenuItem.new)
    file_menu.append(exit_item)

    # Menú Reproducción
    playback_menu = Gtk::Menu.new
    playback_item = Gtk::MenuItem.new(label: "Reproducción")
    playback_item.set_submenu(playback_menu)

    shuffle_item = Gtk::CheckMenuItem.new(label: "Modo Aleatorio")
    shuffle_item.active = @shuffle_mode
    shuffle_item.signal_connect("toggled") { |widget| @shuffle_mode = widget.active? }

    repeat_menu = Gtk::Menu.new
    repeat_item = Gtk::MenuItem.new(label: "Repetición")
    repeat_item.set_submenu(repeat_menu)

    repeat_none = Gtk::CheckMenuItem.new(label: "Sin repetición")
    repeat_one = Gtk::CheckMenuItem.new(label: "Repetir una")
    repeat_all = Gtk::CheckMenuItem.new(label: "Repetir todas")

    repeat_none.signal_connect("toggled") do |widget|
      if widget.active?
        @repeat_mode = :none
        repeat_one.active = false
        repeat_all.active = false
      end
    end

    repeat_one.signal_connect("toggled") do |widget|
      if widget.active?
        @repeat_mode = :one
        repeat_none.active = false
        repeat_all.active = false
      end
    end

    repeat_all.signal_connect("toggled") do |widget|
      if widget.active?
        @repeat_mode = :all
        repeat_none.active = false
        repeat_one.active = false
      end
    end

    case @repeat_mode
    when :one then repeat_one.active = true
    when :all then repeat_all.active = true
    else repeat_none.active = true
    end

    repeat_menu.append(repeat_none)
    repeat_menu.append(repeat_one)
    repeat_menu.append(repeat_all)

    playback_menu.append(shuffle_item)
    playback_menu.append(repeat_item)

    menu_bar.append(file_item)
    menu_bar.append(playback_item)

    main_box.pack_start(menu_bar, expand: false, fill: true, padding: 0)
  end

  def creapaneltop(main_box)
    top_box = Gtk::Box.new(:horizontal, 5)
    
    search_entry = Gtk::SearchEntry.new
    search_entry.signal_connect("search-changed") { |widget| filtro_playlist(widget.text) }
    
    sort_button = Gtk::Button.new(label: "Ordenar")
    sort_button.signal_connect("clicked") { muestramenusort }

    top_box.pack_start(search_entry, expand: true, fill: true, padding: 5)
    top_box.pack_start(sort_button, expand: false, fill: false, padding: 5)

    main_box.pack_start(top_box, expand: false, fill: true, padding: 5)
  end

  def vistaplaylist(main_box)
    @store = Gtk::ListStore.new(String, String, String, String, String)
    @treeview = Gtk::TreeView.new(@store)
    
    renderer = Gtk::CellRendererText.new
    
    columns = [
      ["Título", 0],
      ["Artista", 1],
      ["Álbum", 2],
      ["Duración", 3],
      ["Formato", 4]
    ]

    columns.each do |title, index|
      column = Gtk::TreeViewColumn.new(title, renderer, text: index)
      column.resizable = true
      @treeview.append_column(column)
    end

    @treeview.signal_connect("row-activated") do |tree_view, path, column|
      @current_index = path.indices[0]
      tocasongseleccionada(@current_index)
    end

    scrolled_window = Gtk::ScrolledWindow.new
    scrolled_window.add(@treeview)
    
    main_box.pack_start(scrolled_window, expand: true, fill: true, padding: 5)
  end

  def sehacepanelinfo(main_box)
    @info_box = Gtk::Box.new(:vertical, 5)
    
    @current_song_label = Gtk::Label.new("No hay canción reproduciendo")
    @current_song_label.wrap = true
    
    @artist_label = Gtk::Label.new("Artista: -")
    @album_label = Gtk::Label.new("Álbum: -")
    @format_label = Gtk::Label.new("Formato: -")
    
    @info_box.pack_start(@current_song_label, expand: false, fill: false, padding: 2)
    @info_box.pack_start(@artist_label, expand: false, fill: false, padding: 2)
    @info_box.pack_start(@album_label, expand: false, fill: false, padding: 2)
    @info_box.pack_start(@format_label, expand: false, fill: false, padding: 2)
    
    main_box.pack_start(@info_box, expand: false, fill: false, padding: 5)
  end

  def creacontrolplayback(main_box)
    controls_box = Gtk::Box.new(:horizontal, 10)
    
    buttons = [
      ["⏮", :tocaanterior],
      ["⏪", :atrasasee],
      ["▶", :colocarplay],
      ["⏹", :para_playback],
      ["⏩", :adelantasee],
      ["⏭", :siguientepista]
    ]

    buttons.each do |label, action|
      button = Gtk::Button.new(label: label)
      button.signal_connect("clicked") { send(action) }
      controls_box.pack_start(button, expand: true, fill: true, padding: 5)
    end

    main_box.pack_start(controls_box, expand: false, fill: false, padding: 5)
  end

  def barradeeprogreso(main_box)
    @progress_bar = Gtk::ProgressBar.new
    main_box.pack_start(@progress_bar, expand: false, fill: true, padding: 5)
  end

  def creapanelbajo(main_box)
    bottom_box = Gtk::Box.new(:horizontal, 5)
    
    volume_label = Gtk::Label.new("Volumen:")
    @volume_scale = Gtk::Scale.new(:horizontal, 0, 100, 1)
    @volume_scale.value = @volume * 100
    @volume_scale.signal_connect("value-changed") do |scale|
      @volume = scale.value / 100.0
      actualizovolumen
    end

    bottom_box.pack_start(volume_label, expand: false, fill: false, padding: 5)
    bottom_box.pack_start(@volume_scale, expand: true, fill: true, padding: 5)

    main_box.pack_start(bottom_box, expand: false, fill: true, padding: 5)
  end

  def shortkutstecladin
    @window.signal_connect("key-press-event") do |_, event|
      case event.keyval
      when Gdk::Keyval::KEY_space
        colocarplay
      when Gdk::Keyval::KEY_Left
        atrasasee
      when Gdk::Keyval::KEY_Right
        adelantasee
      when Gdk::Keyval::KEY_Up
        subovolu
      when Gdk::Keyval::KEY_Down
        bajovolu
      end
    end
  end

  def tocasongseleccionada(index)
    return if index.nil? || @playlist.empty?
    
    @current_index = index
    @current_song = @playlist[index]
    
    begin
      para_playback
      case @current_song.format.downcase
      when 'wav'
        Win32::Sound.play(@current_song.path, Win32::Sound::ASYNC)
      when 'mp3'
        play_mp3(@current_song.path)
      end
      
      @is_playing = true
      @start_time = Time.now
      infopanelupda
      empiezoconupdateprogreso
    rescue => e
      muestraerror("Error al reproducir: #{e.message}")
    end
  end

  def play_mp3(path_archivo)
    @wmp = WIN32OLE.new('WMPlayer.OCX')
    @wmp.settings.volume = (@volume * 100).to_i
    @wmp.URL = path_archivo
    @wmp.controls.play
  end

  def para_playback
    begin
      if @current_song&.format&.downcase == 'wav'
        Win32::Sound.stop if @is_playing
      elsif @current_song&.format&.downcase == 'mp3' && @wmp
        @wmp.controls.stop
        @wmp = nil
      end
    rescue
      # Ignorar errores al detener
    ensure
      @is_playing = false
      @progress_bar.fraction = 0.0
      @current_song_label.text = "Reproducción detenida"
      if @progress_updater
        GLib::Source.remove(@progress_updater)
        @progress_updater = nil
      end
    end
  end

  def actualizovolumen
    if @current_song&.format&.downcase == 'wav'
      Win32::Sound.volume = (@volume * 65535).to_i
    elsif @current_song&.format&.downcase == 'mp3' && @wmp
      @wmp.settings.volume = (@volume * 100).to_i
    end
  end

  def empiezoconupdateprogreso
    if @progress_updater
      GLib::Source.remove(@progress_updater)
      @progress_updater = nil
    end
    
    @progress_updater = GLib::Timeout.add(1000) do
      if @is_playing && @current_song && @current_song.duration > 0
        elapsed = Time.now - @start_time
        progress = [elapsed / @current_song.duration, 1.0].min
        @progress_bar.fraction = progress
        
        if progress >= 1.0
          GLib::Idle.add do
            finalsong
            false
          end
        end
        
        true
      else
        false
      end
    end
  end

  def finalsong
    para_playback
    case @repeat_mode
    when :one
      tocasongseleccionada(@current_index)
    when :all
      siguientepista
    end
  end

  def colocarplay
    if @is_playing
      para_playback
    else
      if @current_song
        tocasongseleccionada(@current_index)
      else
        tocasongseleccionada(0) unless @playlist.empty?
      end
    end
  end

  def siguientepista
    return if @playlist.empty?
    
    if @shuffle_mode
      @current_index = rand(@playlist.size)
    else
      @current_index = (@current_index + 1) % @playlist.size
    end
    
    tocasongseleccionada(@current_index)
  end

  def tocaanterior
    return if @playlist.empty?
    
    if @shuffle_mode
      @current_index = rand(@playlist.size)
    else
      @current_index = (@current_index - 1) % @playlist.size
    end
    
    tocasongseleccionada(@current_index)
  end

  def adelantasee
    return unless @current_song
    para_playback
    tocasongseleccionada(@current_index)
  end

  def atrasasee
    return unless @current_song
    para_playback
    tocasongseleccionada(@current_index)
  end

  def actualizovolumen
    Win32::Sound.volume = (@volume * 65535).to_i
  end

  def subovolu
    @volume = [@volume + 0.1, 1.0].min
    @volume_scale.value = @volume * 100
    actualizovolumen
  end

  def bajovolu
    @volume = [@volume - 0.1, 0.0].max
    @volume_scale.value = @volume * 100
    actualizovolumen
  end

  def abro_archv
    dialog = Gtk::FileChooserDialog.new(
      title: "Seleccionar archivos de música",
      parent: @window,
      action: :open,
      buttons: [
        ["Cancelar", :cancel],
        ["Abrir", :accept]
      ]
    )

    filter = Gtk::FileFilter.new
    filter.name = "Archivos de Audio"
    SUPPORTED_FORMATS.each { |format| filter.add_pattern("*.#{format}") }
    dialog.add_filter(filter)
    dialog.select_multiple = true
    dialog.current_folder = @last_folder if @last_folder

    if dialog.run == :accept
      @last_folder = dialog.current_folder
      añadoaplaylist(dialog.filenames)
    end
    dialog.destroy
  end

  def check_carpeta
    dialog = Gtk::FileChooserDialog.new(
      title: "Seleccionar carpeta de música",
      parent: @window,
      action: :select_folder,
      buttons: [
        ["Cancelar", :cancel],
        ["Abrir", :accept]
      ]
    )
    
    dialog.current_folder = @last_folder if @last_folder

    if dialog.run == :accept
      @last_folder = dialog.filename
      veo_songs(dialog.filename)
    end
    dialog.destroy
  end

  def veo_songs(folder_path)
    pattern = "*.{#{SUPPORTED_FORMATS.join(',')}}"
    files = Dir.glob(File.join(folder_path, "**", pattern))
    añadoaplaylist(files)
  end

  def añadoaplaylist(files)
    new_songs = files.map { |file| Song.new(file) }
    @playlist.concat(new_songs)
    refrescaplaylist
  end

  def refrescaplaylist
    @store.clear
    @playlist.each do |song|
      iter = @store.append
      iter[0] = song.title
      iter[1] = song.artist
      iter[2] = song.album
      iter[3] = formato_duracion(song.duration)
      iter[4] = song.format.upcase
    end
  end

  def filtro_playlist(search_text)
    @store.clear
    @playlist.each do |song|
      if song.title.downcase.include?(search_text.downcase) ||
         song.artist.downcase.include?(search_text.downcase) ||
         song.album.downcase.include?(search_text.downcase)
        
        iter = @store.append
        iter[0] = song.title
        iter[1] = song.artist
        iter[2] = song.album
        iter[3] = formato_duracion(song.duration)
        iter[4] = song.format.upcase
      end
    end
  end

  def muestramenusort
    menu = Gtk::Menu.new
    
    ["Título", "Artista", "Álbum", "Formato"].each do |criteria|
      item = Gtk::MenuItem.new(label: "Ordenar por #{criteria}")
      item.signal_connect("activate") { sort_playlist(criteria.downcase.to_sym) }
      menu.append(item)
    end
    
    menu.show_all
    menu.popup_at_pointer
  end

  def sort_playlist(criteria)
    case criteria
    when :título
      @playlist.sort_by! { |song| song.title.downcase }
    when :artista
      @playlist.sort_by! { |song| song.artist.downcase }
    when :álbum
      @playlist.sort_by! { |song| song.album.downcase }
    when :formato
      @playlist.sort_by! { |song| song.format.downcase }
    end
    refrescaplaylist
  end

  def salvate_playlist
    dialog = Gtk::FileChooserDialog.new(
      title: "Guardar lista de reproducción",
      parent: @window,
      action: :save,
      buttons: [
        ["Cancelar", :cancel],
        ["Guardar", :accept]
      ]
    )
    
    if dialog.run == :accept
      File.open(dialog.filename, 'w') do |f|
        @playlist.each { |song| f.puts song.path }
      end
    end
    dialog.destroy
  end

  def carga_playlist
    dialog = Gtk::FileChooserDialog.new(
      title: "Cargar lista de reproducción",
      parent: @window,
      action: :open,
      buttons: [
        ["Cancelar", :cancel],
        ["Abrir", :accept]
      ]
    )
    
    if dialog.run == :accept
      files = File.readlines(dialog.filename).map(&:chomp)
      añadoaplaylist(files.select { |f| File.exist?(f) })
    end
    dialog.destroy
  end

  def formato_duracion(seconds)
    minutes = seconds / 60
    remaining_seconds = seconds % 60
    "%02d:%02d" % [minutes, remaining_seconds]
  end

  def setupdelautosave
    GLib::Timeout.add(60000) { guarda_config; true }
  end

  def carga_configcasode
    if File.exist?(CONFIG_FILE)
      config = JSON.parse(File.read(CONFIG_FILE))
      @last_folder = config['last_folder']
      @volume = config['volume'] || 1.0
      @repeat_mode = (config['repeat_mode'] || 'none').to_sym
      @shuffle_mode = config['shuffle_mode'] || false
    end
  rescue
    @last_folder = nil
    @volume = 1.0
    @repeat_mode = :none
    @shuffle_mode = false
  end

  def guarda_config
    config = {
      'last_folder' => @last_folder,
      'volume' => @volume,
      'repeat_mode' => @repeat_mode.to_s,
      'shuffle_mode' => @shuffle_mode
    }
    File.write(CONFIG_FILE, JSON.pretty_generate(config))
  rescue => e
    puts "Error al guardar la configuración: #{e.message}"
  end

  def muestraerror(message)
    dialog = Gtk::MessageDialog.new(
      parent: @window,
      flags: :destroy_with_parent,
      type: :error,
      buttons: :close,
      message: message
    )
    dialog.run
    dialog.destroy
  end
end

#.............................................................................................................
#iniciar la aplicación
if __FILE__ == $0
  app = MusicPlayer.new
  Gtk.main
end
