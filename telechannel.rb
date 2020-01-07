require 'bundler/setup'
require 'discordrb'
require 'discordrb/webhooks/client'

class Telechannel
  WEBHOOK_NAME_REG = /^Telehook<(\d+)>$/
  EMBED_COLOR = 0xea596e

  def initialize(bot_token)
    @bot = Discordrb::Commands::CommandBot.new(
      token: bot_token,
      prefix: "/",
      help_command: false,
      webhook_commands: false,
      ignore_bots: true
    )

    @link_queues = Hash.new { |hash, key| hash[key] = {} }  # 接続待機
    @link_pairs  = Hash.new { |hash, key| hash[key] = {} }  # 接続済み

    # BOT初期化処理
    @bot.ready do
      @bot.game = "#{@bot.prefix}connect"
    end

    # コマンド共通属性
    @command_attrs = {
      permission_message: "⚠️ **#{@bot.prefix}%name%** コマンドの実行には **チャンネル管理** 権限が必要です",
      required_permissions: [:manage_channels]
    }

    # コネクション作成
    @bot.command(:connect, @command_attrs) do |event, p_channel_id|
      if p_channel_id.nil?
        view_help(event)
        next
      end

      if p_channel_id !~ /^\d+$/
        event.send_message("⚠️ チャンネルIDを指定してください")
        next
      end

      add_link(event.channel, p_channel_id.to_i)
      nil
    end

    # コネクション削除
    @bot.command(:disconnect, @command_attrs) do |event, p_channel_id|
      if p_channel_id.nil?
        view_help(event)
        next
      end

      if p_channel_id !~ /^\d+$/
        event.send_message("⚠️ チャンネルIDを指定してください")
        next
      end
      remove_link(event.channel, p_channel_id.to_i)
      nil
    end

    # 接続中のチャンネルを表示
    @bot.command(:connecting, @command_attrs) do |event|
      resume_links(event.channel)
      event.send_embed do |embed|
        embed.color = EMBED_COLOR
        embed.title = "接続中のチャンネル一覧"

        pair_list = get_pair_list(event.channel)
        if pair_list.empty?
          embed.description = "(接続中のチャンネルはありません)"
        else
          embed.description = ""
          pair_list.each do |pair|
            embed.description += "#{pair[:server_name]} ##{pair[:channel_name]} : **`#{pair[:channel_id]}`**\n"
          end
        end
      end
    end

    # メッセージイベント
    @bot.message do |event|
      next unless event.channel.text?
      next if event.content.start_with?(@bot.prefix)
      send_content(event)
      nil
    end

    # Webhook更新イベント
    @bot.webhook_update do |event|
      check_links(event.channel)
      nil
    end

    # チャンネル削除イベント
    @bot.channel_delete do |event|
      lost_links(event.id)
      nil
    end

    # 招待コマンド
    @bot.mention do |event|
      next if event.content !~ /^<@!?#{@bot.profile.id}> ?invite/
      channel = event.author.pm
      channel.send_embed do |embed|
        embed.color = EMBED_COLOR
        embed.title = "Telechannel に興味をもっていただき、ありがとうございます！"
        embed.description = <<DESC
このBOTは簡単なコマンド操作でチャンネル間の相互チャットを実現できるBOTです。
BOTの使用方法・導入方法は[こちら](https://github.com/GrapeColor/telechannel/blob/master/README.md)のリンクをご覧ください。
DESC
      end
    end

    # デバッグコマンド
    @bot.mention(in: ENV['ADMIN_CHANNEL_ID'].to_i, from: ENV['ADMIN_USER_ID'].to_i) do |event|
      next if event.content !~ /^<@!?\d+> admin (.+)/

      begin
        value = eval($1)
      rescue => exception
        value = exception
      end
      event << "```\n#{value}\n```"
    end
  end

  # BOT起動
  def run(async = false)
    @bot.run(async)
  end

  private

  # ヘルプを表示
  def view_help(event)
    event.send_embed do |embed|
      embed.color = EMBED_COLOR
      embed.title = "Telechannel の使い方"
      embed.description = <<DESC
コマンドで簡単に他サーバー、他チャンネルと接続できるBOTです。

**`#{@bot.prefix}connect [相手のチャンネルID]`** : 指定されたチャンネルと接続します
**`#{@bot.prefix}disconnect [相手のチャンネルID]`** : 指定されたチャンネルを切断します
**`#{@bot.prefix}connecting`** : このチャンネルに接続されているチャンネルを表示します

このチャンネルと接続するには、
相手のチャンネルで **`#{@bot.prefix}connect #{event.channel.id}`** を実行してください。

[詳しい使用方法](https://github.com/GrapeColor/telechannel/blob/master/README.md)
DESC
    end
  end

  # ペアまたはキューに登録
  def add_link(channel, p_channel_id, no_msg = false)
    # チャンネル取得
    p_channel = get_p_channel(p_channel_id, channel && !no_msg)
    return unless p_channel
    if p_channel.id == channel.id
      channel.send_message("⚠️ **指定されたチャンネルはこのチャンネルです**") unless no_msg
      return
    end

    # 登録済み確認
    if @link_queues[channel.id][p_channel.id]
      channel.send_message(
        "ℹ️ 既に **#{p_channel.server.name} ##{p_channel.name}** との接続を待っています\n" + 
        "相手チャンネルで次のコマンドを実行してください **`#{@bot.prefix}connect #{channel.id}`**"
      ) unless no_msg
      return
    end
    if @link_pairs[channel.id][p_channel.id]
      channel.send_message("ℹ️ **指定されたチャンネルは接続済みです**") unless no_msg
      return
    end

    # ウェブフックを作成
    webhook = get_webhook(channel, p_channel)
    return unless webhook

    # キューを取り出す
    p_webhook = @link_queues[p_channel.id].delete(channel.id)

    if p_webhook.nil?
      # キューに登録
      @link_queues[channel.id][p_channel.id] = webhook
      channel.send_message(
        "ℹ️ **#{p_channel.server.name} ##{p_channel.name}** との接続を待っています\n" +
        "相手チャンネルで次のコマンドを実行してください **`#{@bot.prefix}connect #{channel.id}`**"
      ) unless no_msg
    else
      # ペアに登録
      @link_pairs[channel.id][p_channel.id] = p_webhook
      @link_pairs[p_channel.id][channel.id] = webhook
      channel.send_message(
        "✅ **#{p_channel.server.name} ##{p_channel.name}** と接続されました\n" +
        "切断するには次のコマンドを実行してください **`#{@bot.prefix}disconnect #{p_channel.id}`**"
      ) unless no_msg
      p_channel.send_message(
        "✅ **#{channel.server.name} ##{channel.name}** と接続されました\n" +
        "切断するには次のコマンドを実行してください **`#{@bot.prefix}disconnect #{channel.id}`**"
      ) unless no_msg
    end

    p_channel
  end

  # ペアまたはキューの削除
  def remove_link(channel, p_channel_id, no_msg = false)
    # チャンネル取得
    p_channel = get_p_channel(p_channel_id)
    if p_channel && p_channel.id == channel.id
      channel.send_message("⚠️ **指定されたチャンネルはこのチャンネルです**") unless no_msg
      return
    end

    p_webhook = @link_pairs[channel.id].delete(p_channel_id)

    # キューの削除
    if p_webhook.nil?
      webhook = @link_queues[channel.id].delete(p_channel_id)
      if webhook
        begin; webhook.delete
        rescue; nil; end
        if p_channel
          channel.send_message("ℹ️ **#{p_channel.server.name} ##{p_channel.name}** の接続待ちがキャンセルされました") unless no_msg
        else
          channel.send_message("ℹ️ 接続待ちがキャンセルされました") unless no_msg
        end
      else
        channel.send_message("⚠️ **指定されたチャンネルは接続されていません**") unless no_msg

        # 未登録のWebhookを削除
        channel.webhooks.each do |webhook|
          next if webhook.owner.id != @bot.profile.id
          next if webhook.name !~ WEBHOOK_NAME_REG || $1.to_i != p_channel_id
          webhook.delete
        end
      end
      return p_channel
    end

    # ペアの削除
    webhook = @link_pairs[p_channel_id].delete(channel.id)
    if webhook
      begin; webhook.delete
      rescue; nil; end
      if p_channel
        channel.send_message("⛔ **#{p_channel.server.name} ##{p_channel.name}** と切断されました") unless no_msg
      else
        channel.send_message("⛔ 接続相手と切断されました") unless no_msg
      end
    end

    begin; p_webhook.delete
    rescue; nil; end
    if p_channel
      p_channel.send_message("⛔ **#{channel.server.name} ##{channel.name}** と切断されました") unless no_msg
    end

    p_channel
  end

  # すべての接続を切断
  def remove_all_links(channel)
    # ペア情報を元にWebhookを削除
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      remove_link(channel, p_channel_id)
    end

    # チャンネルのWebhookを削除
    channel.webhooks.each do |webhook|
      webhook.delete if webhook.owner.id == @bot.profile.id
    end
  end

  # チャンネルIDの接続先をすべて切断
  def lost_links(channel_id)
    @link_pairs[channel_id].each do |p_channel_id, p_webhook|
      p_channel = get_p_channel(p_channel_id)
      remove_link(p_channel, channel_id)
    end
  end

  # 接続確認
  def check_links(channel)
    webhook_ids = channel.webhooks.map do |webhook|
      webhook.name =~ WEBHOOK_NAME_REG
      [webhook.id, $1.to_i]
    end.to_h

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      webhook = @link_pairs[p_channel_id][channel.id]
      unless webhook_ids.has_key?(webhook.id) && webhook_ids[webhook.id] == p_channel_id
        remove_link(channel, p_channel_id)
      end
    end
  end

  # メッセージ送信
  def send_content(event)
    channel = event.channel
    message = event.message

    resume_links(channel)

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      client = Discordrb::Webhooks::Client.new(id: p_webhook.id, token: p_webhook.token)

      if message.author.respond_to?(:display_name)
        display_name = message.author.display_name
      else
        display_name = message.author.username
      end

      begin
        # メッセージ送信
        if !message.content.strip.empty?
          client.execute do |builder|
            builder.avatar_url = message.author.avatar_url
            builder.username = "#{display_name} (@#{channel.server.name} ##{channel.name})"
            builder.content += message.content
          end
        end

        # 添付ファイル(CDNのURL)送信
        if !message.attachments.empty?
          client.execute do |builder|
            builder.avatar_url = message.author.avatar_url
            builder.username = "#{display_name} (@#{channel.server.name} ##{channel.name})"
            builder.content = "(添付ファイル)\n"
            message.attachments.each do |attachment|
              builder.content += attachment.spoiler? ? "📎 ||#{attachment.url}||\n" : "📎 #{attachment.url}\n"
            end
          end
        end
      rescue RestClient::NotFound
        remove_link(channel, p_channel_id)
      end
    end
  end

  # 接続再構築
  def resume_links(channel)
    return if @link_pairs.has_key?(channel.id) || @link_queues.has_key?(channel.id)

    channel.webhooks.each do |webhook|
      next if webhook.owner.id != @bot.profile.id
      next if webhook.name !~ WEBHOOK_NAME_REG
      p_channel_id = $1.to_i

      # キュー登録
      p_channel = add_link(channel, p_channel_id, true)
      unless p_channel
        remove_link(channel, p_channel_id)
        next
      end

      # ペア登録
      p_channel.webhooks.each do |webhook|
        next if webhook.owner.id != @bot.profile.id
        next if webhook.name !~ WEBHOOK_NAME_REG || $1.to_i != channel.id
        add_link(p_channel, channel.id, true)
      end
    end
  end

  # 相手チャンネルを取得
  def get_p_channel(p_channel_id, channel = nil)
    begin
      p_channel = @bot.channel(p_channel_id)
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠️ **指定されたチャンネルにBOTが導入されていません**") if channel
      return nil
    end

    if p_channel.nil?
      channel.send_message("⚠️ **指定されたチャンネルは存在しません**") if channel
      return nil
    end

    p_channel
  end

  # Webhookの取得または作成
  def get_webhook(channel, p_channel)
    # 既存のWebhookを取得
    begin
      webhooks = channel.webhooks.select do |webhook|
        webhook.name =~ WEBHOOK_NAME_REG
        $1.to_i == p_channel.id && webhook.owner.id == @bot.profile.id
      end
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠️ BOTに **ウェブフックの管理** 権限が必要です")
      return nil
    end

    # Webhookを作成
    if webhooks.empty?
      begin
        webhook = channel.create_webhook("Telehook<#{p_channel.id}>")
      rescue Discordrb::Errors::NoPermission
        channel.send_message("⚠️ BOTに **ウェブフックの管理** 権限が必要です")
        return nil
      end
      return webhook
    end

    webhooks.first
  end

  # 接続済みリスト取得
  def get_pair_list(channel)
    @link_pairs[channel.id].map do |p_channel_id, p_webhook|
      p_channel = get_p_channel(p_channel_id)
      next unless p_channel
      { server_name: p_channel.server.name, channel_name: p_channel.name, channel_id: p_channel.id }
    end
  end
end
