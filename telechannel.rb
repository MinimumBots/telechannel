require 'bundler/setup'
require 'stringio'
require 'yaml'
require 'discordrb'
require 'discordrb/webhooks'

class Telechannel
  MESSAGES_FILE = File.expand_path('../messages.yml', __FILE__)
  MESSAGES_LIST = File.open(MESSAGES_FILE, 'r') { |f| YAML.load(f) }
  REQUIRE_PERMIT = {
    manage_webhooks: "ウェブフックの管理",
    read_messages: "メッセージを読む",
    send_messages: "メッセージを送信",
    manage_messages: "メッセージの管理",
    embed_links: "埋め込みリンク",
    read_message_history: "メッセージ履歴を読む",
    add_reactions: "リアクションの追加",
  }

  def initialize(bot_token)
    @confirm_queue     = Hash.new { |hash, key| hash[key] = [] } # 接続承認待ちチャンネル
    @link_pairs        = Hash.new { |hash, key| hash[key] = {} } # 接続済み
    @webhook_relations = Hash.new
    @related_messages  = Hash.new { |hash, key| hash[key] = {} } # 転送メッセージの関係性
    @error_channels = [] # Webhook取得に失敗したサーバー一覧

    @bot = Discordrb::Commands::CommandBot.new(
      token: bot_token,
      prefix: "/",
      help_command: false,
    )

    # BOT初期化処理
    @bot.ready do
      @bot.game = "/connect でヘルプ表示"
      resume_links
    end

    # コネクション作成
    @bot.command(:connect) do |event, p_channel_id|
      next unless check_permission(event.channel, event.author)
      next unless p_channel = get_arg_channel(event.channel, p_channel_id)

      new_link(event.channel, p_channel, event.author)
      nil
    end

    # コネクション削除
    @bot.command(:disconnect) do |event, p_channel_id|
      next unless check_permission(event.channel, event.author)
      next unless p_channel = get_arg_channel(event.channel, p_channel_id)

      remove_link(event.channel, p_channel, event.author)
      nil
    end

    # 接続中のチャンネルを表示
    @bot.command(:connecting) do |event|
      next unless check_permission(event.channel, event.author)
      listing_links(event)
      nil
    end

    # BOTに必要な権限の検証
    @bot.command(:connectable) do |event|
      next unless check_permission(event.channel, event.author)
      test_permittion(event.channel)
      nil
    end

    # メッセージイベント
    @bot.message do |event|
      transfer_message(event)
      nil
    end

    # メッセージ削除イベント
    @bot.message_delete do |event|
      destroy_message(event.id)
      nil
    end

    # メッセージ編集イベント
    @bot.message_edit do |event|
      edited_message(event)
      nil
    end

    # ウェブフック更新イベント
    @bot.webhook_update do |event|
      check_webhooks(event.channel)
      nil
    end

    # 招待コマンド
    @bot.mention do |event|
      next if event.content !~ /^<@!?\d+> *invite/
      channel = event.author.pm
      channel.send_embed do |embed|
        invite = MESSAGES_LIST[:invite]
        embed.color = invite[:color]
        embed.title = invite[:title]
        embed.description = invite[:description]
      end
    end

    # デバッグコマンド
    @bot.mention(in: ENV['ADMIN_CHANNEL_ID'].to_i, from: ENV['ADMIN_USER_ID'].to_i) do |event|
      next if event.content !~ /^<@!?\d+> admin (.+)/

      $stdout = StringIO.new

      begin
        value = eval("pp(#{$1})")
        log = $stdout.string
      rescue => exception
        log = exception
      end

      $stdout = STDOUT

      event.send_message("**STDOUT**")
      log.to_s.scan(/.{1,#{2000 - 8}}/m) do |split|
        event.send_message("```\n#{split}\n```")
      end
      
      event.send_message("**RETURN VALUE**")
      value.to_s.scan(/.{1,#{2000 - 8}}/m) do |split|
        event.send_message("```\n#{split}\n```")
      end
    end
  end

  # BOT起動
  def run(async = false)
    @bot.run(async)
  end

  private

  # 実行権限チェック
  def check_permission(channel, member)
    return if member.bot_account?
    return true if channel.private?

    return unless member.is_a?(Discordrb::Member)
    member.permission?(:manage_channels, channel)
  end

  # 引数のチャンネルを取得
  def get_arg_channel(channel, p_channel_id)
    # ヘルプ表示(パラメータなし)
    if p_channel_id.nil?
      channel.send_embed do |embed|
        help = MESSAGES_LIST[:help]
        embed.color = help[:color]
        embed.title = help[:title]
        embed.description = help[:description]
      end
      return
    end

    # チャンネルが指定されていない
    if p_channel_id !~ /^(\d+)$/ && p_channel_id !~ /^<#(\d+)>$/
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ チャンネルIDを指定してください"
        embed.description = "コマンドのパラメータにチャンネルID、またはチャンネルメンションを指定してください。"
      end
      return
    end

    # チャンネルIDを解決できるか
    begin
      p_channel = @bot.channel($1)
    rescue
      p_channel = nil
    end

    if p_channel.nil?
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 指定されたチャンネルが見つかりません"
        embed.description = "指定したチャンネルが存在しないか、BOTが導入されていません。"
      end
      return
    end

    # チャンネルが同一ではないか
    if channel == p_channel
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 指定されたチャンネルはこのチャンネルです"
        embed.description = "このチャンネル自身に対して接続することはできません。"
      end
      return
    end

    p_channel
  end

  #================================================

  # 新しい接続
  def new_link(channel, p_channel, user)
    # 接続可能か検証
    return unless link_validation(channel, p_channel, user)

    # 接続方法選択
    if p_channel.private? || channel.private?
      receive = p_channel.private?
      send    = channel.private?
    elsif p_channel.category?
      receive = true
      send    = false
    else
      receive, send = link_select(channel, p_channel, user)
    end
    return unless receive || send

    # 相手チャンネル上のメンバーデータ
    p_member = @bot.member(p_channel.server, user.id) unless p_channel.private?
    # 相手チャンネル上で権限を持つか
    p_permit = p_member && p_member.permission?(:manage_channels, channel)

    # 相手チャンネル上で権限を持たないとき
    unless p_permit
      p_member, confirm_ch = link_confirmation(channel, p_channel)
      return if p_member.nil?
    end

    # 双方向接続・一方向接続(送信側)の場合
    if send
      return unless link_create_other(channel, p_channel, p_permit)
    end

    # 自チャンネルのリンクを作成
    if !receive || create_link(channel, p_channel)
      link_success(channel, p_channel, receive, send, user, p_member)
    else
      link_failure(channel, p_channel, send, confirm_ch)
    end
  end

  # 接続済み検証
  def link_validation(channel, p_channel, user)
    return if @confirm_queue[channel.id].include?(p_channel.id)

    receive = @link_pairs[p_channel.id].has_key?(channel.id)
    send    = @link_pairs[channel.id].has_key?(p_channel.id)
    unless receive || send
      receive = @link_pairs[p_channel.id].has_key?(channel.parent_id)
      send    = @link_pairs[channel.parent_id].has_key?(p_channel.id)
    end

    if receive || send
      channel.send_embed do |embed|
        embed.color = 0x3b88c3
        embed.title = "ℹ️ すでに接続されています"

        embed.description = "**#{gen_channel_disp(channel, p_channel)}** と "
        if receive && send
          embed.description += "**双方向接続** されています。"
        else
          embed.description += "**一方向接続(#{send ? "送" : "受" }信側)** されています。"
        end
        embed.description += "\n\n切断は `/disconnect #{p_channel.id}` で行えます。"
      end
      return
    end

    if channel.private? && p_channel.private?
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ プライベートチャンネル同士は接続できません"
        embed.description = "ダイレクトメッセージや、グループチャット同士を接続することはできません。"
      end
      return
    end

    true
  end

  # 接続方式の選択
  def link_select(channel, p_channel, user)
    message = channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "🆕 ##{p_channel.name} との接続方法を選んでください(1分以内)"
      embed.description = "↔️ **双方向接続**\n  相手チャンネルと互いにメッセージを送信します\n\n"
      embed.description += "⬅️ **一方向接続(受信側)**\n相手チャンネルのメッセージをこのチャンネルへ送信します\n\n"
      embed.description += "➡️ **一方向接続(送信側)**\nこのチャンネルのメッセージを相手チャンネルへ送信します"
    end
    message.create_reaction("↔️")
    message.create_reaction("⬅️")
    message.create_reaction("➡️")

    # 選択待ち
    receive = nil
    send = nil
    await_event = @bot.add_await!(Discordrb::Events::ReactionAddEvent, { timeout: 60 }) do |event|
      next if event.message != message || event.user != user

      case event.emoji.name
      when "↔️"; send, receive = true, true
      when "➡️"; send, receive = true, false
      when "⬅️"; send, receive = false, true
      else; next
      end

      true
    end
    message.delete

    return if await_event.nil?  # イベントタイムアウト

    return receive, send
  end

  # 接続承認処理
  def link_confirmation(channel, p_channel)
    message = channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ 相手チャンネルでコマンドを実行してください(10分以内)"
      embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
      embed.description += " で以下のコマンドを実行してください。\n```/connect #{channel.id}```"
    end

    # 承認コマンド入力待ち
    p_member = nil
    confirm_ch = nil
    @confirm_queue[p_channel.id] << channel.id
    await_event = @bot.add_await!(Discordrb::Events::MessageEvent, { timeout: 600 }) do |event|
      next if event.content != "/connect #{channel.id}"
      if event.channel != p_channel
        next unless event.channel.parent_id
        next if event.channel.category != p_channel
      end

      p_member = event.author
      next unless p_channel.private? || p_member.permission?(:manage_channels, p_channel)
      confirm_ch = event.channel
      true
    end
    @confirm_queue[p_channel.id].delete(channel.id)
    message.delete

    # イベントタイムアウト
    if await_event.nil?
      channel.send_embed do |embed|
        embed.color = 0xbe1931
        embed.title = "⛔ 接続待ちがタイムアウトしました"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
        embed.description += " で10分以内に権限を持ったメンバーによる指定コマンドの実行がありませんでした。\n"
        embed.description += "最初からコマンドを実行しなおしてください。"
      end
      return
    end

    return p_member, confirm_ch
  end

  # 相手側のリンクを作成
  def link_create_other(channel, p_channel, p_permit)
    unless create_link(p_channel, channel)
      channel.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 相手チャンネルと接続できませんでした"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}** でウェブフックを作成できませんでした。\n"
        embed.description += "チャンネルのウェブフックの作成数が上限(10個)に達していないか、"
        embed.description += "BOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
      end

      # 承認コマンドを要求していた場合
      if confirm_ch
        confirm_ch.send_embed do |embed|
          embed.color = 0xffcc4d
          embed.title = "⚠️ 相手チャンネルと接続できませんでした"
          embed.description = "**このチャンネル** でウェブフックを作成できませんでした。\n"
          embed.description += "チャンネルのウェブフックの作成数が上限(10個)に達していないか、"
          embed.description += "BOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
        end
      end
      return
    end

    true
  end

  # 接続成功(自チャンネルでのWebhook作成成功)
  def link_success(channel, p_channel, receive, send, user, p_user)
    channel.send_embed do |embed|
      embed.color = 0x77b255
      embed.title = "✅ 相手チャンネルと接続しました"

      embed.description = "**#{gen_channel_disp(channel, p_channel)}** と "
      if receive && send
        embed.description += "**双方向接続** しました。"
      else
        embed.description += "**一方向接続(#{send ? "送" : "受" }信側)** しました。"
      end
      embed.description += "\n\n切断は `/disconnect #{p_channel.id}` で行えます。"

      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end

    return if p_channel.category?
    p_channel.send_embed do |embed|
      embed.color = 0x77b255
      embed.title = "✅ 相手チャンネルと接続しました"

      embed.description = "**#{gen_channel_disp(p_channel, channel)}** と "
      if receive && send
        embed.description += "**双方向接続** しました。"
      else
        embed.description += "**一方向接続(#{send ? "受" : "送" }信側)** しました。"
      end
      embed.description += "\n\n切断は `/disconnect #{channel.id}` で行えます。"

      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: p_user.distinct,
        icon_url: p_user.avatar_url
      )
    end
  end

  # 接続失敗(自チャンネルでのWebhook作成失敗)
  def link_failure(channel, p_channel, send, confirm_ch)
    destroy_link(p_channel, channel) if send  # 相手チャンネルのリンクをロールバック

    channel.send_embed do |embed|
      embed.color = 0xffcc4d
      embed.title = "⚠️ 相手チャンネルと接続できませんでした"
      embed.description = "**このチャンネル** でウェブフックを作成できませんでした。\n"
      embed.description += "チャンネルのウェブフックの作成数が上限(10個)に達していないか、"
      embed.description += "BOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
    end

    # 承認コマンドを要求していた場合
    if confirm_ch
      confirm_ch.send_embed do |embed|
        embed.color = 0xffcc4d
        embed.title = "⚠️ 相手チャンネルと接続できませんでした"
        embed.description = "**#{gen_channel_disp(p_channel, channel)}** でウェブフックを作成できませんでした。\n"
        embed.description += "チャンネルのウェブフックの作成数が上限(10個)に達していないか、"
        embed.description += "BOTの権限が十分か確認し、最初からコマンドを実行しなおしてください。"
      end
    end
  end

  #================================================

  # 接続の切断
  def remove_link(channel, p_channel, user)
    unless @link_pairs[channel.id].has_key?(p_channel.id) || @link_pairs[p_channel.id].has_key?(channel.id)
      category = channel.category if channel.parent_id
      unless category || @link_pairs[category.id].has_key?(p_channel.id) || @link_pairs[p_channel.id].has_key?(category.id)
        channel.send_embed do |embed|
          embed.color = 0xffcc4d
          embed.title = "⚠️ 指定されたチャンネルは接続していません"
          embed.description = "接続には以下のコマンドを使用してください。\n"
          embed.description += "```/connect [チャンネルID or チャンネルメンション]```"
        end
        return
      end
    end

    destroy_link(category || channel, p_channel)
    destroy_link(p_channel, category || channel)

    channel.send_embed do |embed|
      embed.color = 0xbe1931
      embed.title = "⛔ 接続が切断されました"
      embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
      embed.description += " と接続が切断されました。"
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end

    return if p_channel.category?
    p_channel.send_embed do |embed|
      embed.color = 0xbe1931
      embed.title = "⛔ 接続が切断されました"
      embed.description = "**#{gen_channel_disp(p_channel, category || channel)}**"
      embed.description += " と接続が切断されました。"
      embed.footer = Discordrb::Webhooks::EmbedFooter.new(
        text: user.distinct,
        icon_url: user.avatar_url
      )
    end
  end

  #================================================

  # 接続の再開
  def resume_links
    @bot.servers.each do |_, server|
      server.text_channels.each {|channel| resume_channel_links(channel) }
    end
  end

  # 指定サーバーの接続再開
  def resume_channel_links(channel)
    begin
      webhooks = channel.webhooks
    rescue
      @error_channels << channel.id
      return
    end

    webhooks.each do |webhook|
      next if webhook.owner != @bot.profile

      begin
        p_channel = @bot.channel(webhook.name[/Telehook<(\d+)>/, 1])
      rescue
        webhook.delete("Other a channel have been lost.")

        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "相手チャンネルが見つからないため、接続が切断されました。"
        end
        next
      end
      next unless p_channel

      # 重複ウェブフックを削除
      if @link_pairs[p_channel.id].has_key?(channel.id)
        webhook.delete if webhook != @link_pairs[p_channel.id][channel.id]
        next
      end

      @webhook_relations[webhook.id] = p_channel.id
      @link_pairs[p_channel.id][channel.id] = webhook
    end

    true
  end

  #================================================

  # 接続作成(p_channel ⇒ channel[webhook])
  def create_link(channel, p_channel)
    if @error_channels.delete(channel.id)
      return unless resume_channel_links(channel)
    end

    begin
      webhook = channel.create_webhook(
        "Telehook<#{p_channel.id}>",
        @webhook_icon,
        "To receive messages from other a channel."
      )
    rescue; return; end
    
    @webhook_relations[webhook.id] = p_channel.id
    @link_pairs[p_channel.id][channel.id] = webhook
  end

  # 接続削除
  def destroy_link(channel, p_channel)
    webhook = @link_pairs[p_channel.id].delete(channel.id)
    return if webhook.nil?

    begin
      webhook.delete("To disconnect from other a channel.")
    rescue; nil; end
    @webhook_relations.delete(webhook.id)
    true
  end

  # 接続相手喪失
  def lost_link(channel, p_channel_id)
    @link_pairs[channel.id].delete(p_channel_id)
    webhook = @link_pairs[p_channel_id].delete(channel.id)
    return if webhook.nil?

    begin
      webhook.delete("Other a channel have been lost.")
    rescue; nil; end
    @webhook_relations.delete(webhook.id)
  end

  #================================================

  # メッセージ転送
  def transfer_message(event, send_list = {})
    return if event.author.bot_account?

    channel = event.channel
    message = event.message

    if send_list.empty?
      send_list.merge!(@link_pairs[channel.id]) if @link_pairs.has_key?(channel.id)
      send_list.merge!(@link_pairs[channel.parent_id]) if @link_pairs.has_key?(channel.parent_id)
    end
    return if send_list.empty?
    posts = []

    send_list.each do |p_channel_id, p_webhook|
      begin
        p_channel = @bot.channel(p_channel_id)
      rescue
        lost_link(channel, p_channel_id)
        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "相手チャンネルが見つからないため、接続が切断されました。"
        end
        next
      end

      posts << Thread.new { post_webhook(channel, p_channel, p_webhook, message) }
    end

    posts.each {|post| post.join }
  end

  # Webhookへの送信処理
  def post_webhook(channel, p_channel, p_webhook, message)
    client = Discordrb::Webhooks::Client.new(id: p_webhook.id, token: p_webhook.token)

    # メッセージ送信
    unless message.content.empty?
      await = chase_message(p_channel, p_webhook, message)
      execute = execute_webhook(channel, p_channel, client, message.author, message.content, await)

      await.join
      execute.join
    end

    # 添付ファイル(CDNのURL)送信
    unless message.attachments.empty?
      content = message.attachments.map do |attachment|
        attachment.spoiler? ? "||#{attachment.url}||" : attachment.url
      end.join("\n")

      await = chase_message(p_channel, p_webhook, message)
      execute = execute_webhook(channel, p_channel, client, message.author, content, await)

      await.join
      execute.join
    end
  end

  # メッセージ追跡
  def chase_message(p_channel, p_webhook, message)
    Thread.new do
      @bot.add_await!(Discordrb::Events::MessageEvent, { timeout: 60, from: p_webhook.id }) do |event|
        next if event.author.name !~ /^#{message.author.distinct}/
        next if event.message.id < message.id
        @related_messages[message.id][event.message.id] = p_channel.id
        true
      end
    end
  end

  # Webhook実行
  def execute_webhook(channel, p_channel, client, author, content, await)
    Thread.new do
      begin
        client.execute do |builder|
          builder.avatar_url = author.avatar_url
          builder.username = gen_webhook_username(channel, p_channel, author)
          builder.content = content
        end
      rescue RestClient::NotFound
        await.kill  # メッセージ追跡スレッドを終了

        destroy_link(channel, p_channel)
        destroy_link(p_channel, channel)

        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
          embed.description += " のウェブフックが見つからないため、接続が切断されました。"
        end unless channel.category?

        p_channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description += "**このチャンネル** のウェブフックが見つからないため、接続が切断されました。"
        end
      rescue
        await.kill  # メッセージ追跡スレッドを終了
      end
    end
  end

  # 関係するメッセージの削除
  def destroy_message(message_id)
    return unless p_messages = @related_messages.delete(message_id)

    p_messages.each do |p_message_id, p_channel_id|
      begin
        Discordrb::API::Channel.delete_message(@bot.token, p_channel_id, p_message_id)
      rescue; next; end
    end
  end

  # 関係するメッセージの編集
  def edited_message(event)
    return unless p_messages = @related_messages.delete(event.message.id)

    send_list = p_messages.map do |p_message_id, p_channel_id|
      begin
        response = Discordrb::API::Channel.messages(@bot.token, p_channel_id, 2)
        p_message = Discordrb::Message.new(JSON.parse(response)[0], @bot)
      rescue; next; end

      next if p_message.id != p_message_id

      p_message.delete

      # 添付ファイル付きメッセージの本文を削除
      p_message = Discordrb::Message.new(JSON.parse(response)[1], @bot)
      p_message.delete if p_messages.has_key?(p_message.id)

      # 相手ウェブフックを取得
      p_webhook = @link_pairs[event.channel.id][p_channel_id]
      p_webhook = @link_pairs[event.channel.parent_id][p_channel_id] unless p_webhook

      [p_channel_id, p_webhook]
    end.compact.to_h

    transfer_message(event, send_list)
  end

  #================================================

  # ウェブフックの変更を検証
  def check_webhooks(channel)
    begin
      webhooks = channel.webhooks
    rescue
      @link_pairs.each {|key, _| key.delete(channel.id) }
      @error_channels << channel.id
      return
    end

    webhooks.each do |webhook|
      next if webhook.owner != @bot.profile

      p_channel_id = @webhook_relations[webhook.id]
      next if webhook.name =~ /Telehook<#{p_channel_id}>/

      begin
        p_channel = @bot.channel(p_channel_id)
      rescue
        lost_link(channel, p_channel_id)
        channel.send_embed do |embed|
          embed.color = 0xbe1931
          embed.title = "⛔ 接続が切断されました"
          embed.description = "ウェブフックの名前が変更されたため、接続を切断しました。"
        end
        next
      end

      destroy_link(channel, p_channel)
      destroy_link(p_channel, channel)

      channel.send_embed do |embed|
        embed.color = 0xbe1931
        embed.title = "⛔ 接続が切断されました"
        embed.description = "**#{gen_channel_disp(channel, p_channel)}**"
        embed.description += " と接続していたウェブフックの名前が変更されたため、接続を切断しました。"
      end

      next if p_channel.category?
      p_channel.send_embed do |embed|
        embed.color = 0xbe1931
        embed.title = "⛔ 接続が切断されました"
        embed.description = "**#{gen_channel_disp(p_channel, channel)}**"
        embed.description += " のウェブフックが見つからないため、接続が切断されました。"
      end
    end
  end

  #================================================

  # 接続済みリストを表示
  LINK_MODE_ICONS = { mutual: "↔️", receive: "⬅️", send: "➡️" }
  def listing_links(event)
    channel = event.channel

    link_list = {}
    gen_link_list(link_list, channel)
    gen_link_list(link_list, channel.category) if channel.parent_id

    if link_list.empty?
      channel.send_embed do |embed|
        embed.color = 0x3b88c3
        embed.title = "ℹ️ 接続中のチャンネルはありません"
      end
      return
    end

    channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ 接続中のチャンネル一覧"
      embed.description = "↔️ 双方向接続　⬅️ 一方向接続(受信側)　➡️ 一方向接続(送信側)\n"
      link_list.each do |p_channel_id, item|
        embed.description += "\n#{LINK_MODE_ICONS[item[:mode]]} #{item[:name]}　🆔 `#{p_channel_id}`"
      end
    end
  end

  def gen_link_list(link_list, channel)
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      begin
        p_channel = @bot.channel(p_channel_id)
      rescue; next; end
      link_list[p_channel.id] = { name: gen_channel_disp(channel, p_channel), mode: :send }
      link_list[p_channel.id][:mode] = :mutual if @link_pairs[p_channel.id][channel.id]
    end

    @link_pairs.each do |p_channel_id, pair_data|
      next if link_list.has_key?(p_channel_id)

      if pair_data.find {|channel_id, _| channel_id == channel.id }
        begin
          p_channel = @bot.channel(p_channel_id)
        rescue; next; end
        link_list[p_channel.id] = { name: gen_channel_disp(channel, p_channel), mode: :receive }
      end
    end
  end

  #================================================

  # 権限の検証
  def test_permittion(channel)
    if channel.private?
      channel.send_embed do |embed|
        embed.color = 0x3b88c3
        embed.title = "ℹ️ 一方向接続(送信側)のみ使用できます"
      end
      return
    end

    bot_member = channel.server.member(@bot.profile.id)

    channel.send_embed do |embed|
      embed.color = 0x3b88c3
      embed.title = "ℹ️ BOTに必要な権限一覧"
      embed.description = ""
      REQUIRE_PERMIT.each do |action, summary|
        embed.description += bot_member.permission?(action, channel) ? "✅" : "⚠️"
        embed.description += " #{summary}\n"
      end
    end
  end

  #================================================

  # 相手チャンネル表示取得
  def gen_channel_disp(channel, p_channel)
    if p_channel.server == channel.server
      return p_channel.category? ? "カテゴリ: #{p_channel.name}" : p_channel.mention
    end

    server_name = if p_channel.pm?
                    "DMチャンネル: "
                  elsif p_channel.group?
                    "グループチャット: "
                  elsif p_channel.category?
                    "#{p_channel.server.name} カテゴリ: "
                  else
                    "#{p_channel.server.name}: #"
                  end

    "#{server_name}#{p_channel.name}"
  end

  # Webhookのユーザー名生成
  def gen_webhook_username(channel, p_channel, user)
    if channel.server == p_channel.server
      return "#{user.distinct} (#{channel.category? ? "カテゴリ: " : "#"}#{channel.name})"
    end

    server_name = if channel.pm?
                    "DMチャンネル: "
                  elsif channel.group?
                    "グループチャット: "
                  elsif channel.category?
                    "#{channel.server.name} カテゴリ: "
                  else
                    "#{channel.server.name}: #"
                  end

    "#{user.distinct} (#{server_name}#{channel.name})"
  end
end
