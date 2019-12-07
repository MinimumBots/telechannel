require 'bundler/setup'
require 'discordrb'
require 'discordrb/webhooks/client'

class Telechannel
  def initialize(bot_token)
    @bot = Discordrb::Commands::CommandBot.new(
      token: bot_token,
      prefix: '+',
      help_command: false,
      webhook_commands: false,
      ignore_bots: true
    )

    @link_queues = Hash.new { |hash, key| hash[key] = {} }  # 接続待機
    @link_pairs  = Hash.new { |hash, key| hash[key] = {} }  # 接続済み

    # BOT初期化処理
    @bot.ready do
      @bot.game = "#{@bot.prefix}help"
    end

    # コマンド共通属性
    @command_attrs = {
      permission_message: "⚠ **#{@bot.prefix}%name%** の実行には **チャンネル管理** 権限が必要です",
      required_permissions: [:manage_channels]
    }

    # コネクション作成
    @bot.command(:link, @command_attrs) do |event, p_channel_id|
      next if p_channel_id !~ /^\d+$/
      add_link(event.channel, p_channel_id.to_i)
    end

    # コネクション削除
    @bot.command(:unlink, @command_attrs) do |event, p_channel_id|
      next if p_channel_id !~ /^\d+$/
      remove_link(event.channel, p_channel_id.to_i)
    end

    # 全コネクションを削除
    @bot.command(:clear, @command_attrs) do |event|
      
    end

    # Webhook更新イベント
    @bot.webhook_update do |event|
      check_links(event.channel)
    end

    # メッセージイベント
    @bot.message do |event|
      send_content(event)
    end
  end

  # BOT起動
  def run(async = false)
    @bot.run(async)
  end

  private

  # ペアまたはキューに登録
  def add_link(channel, p_channel_id)
    # チャンネル取得
    p_channel = get_p_channel(p_channel_id, channel)
    return unless p_channel
    if p_channel.id == channel.id
      channel.send_message("⚠ **指定されたチャンネルはこのチャンネルです**")
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
        "ℹ **#{p_channel.server.name} ##{p_channel.name}** との接続を待っています\n" +
        "相手のチャンネルでこのコマンドを実行してください **`#{@bot.prefix}link #{channel.id}`**"
      )
    else
      # ペアに登録
      @link_pairs[channel.id][p_channel.id] = p_webhook
      @link_pairs[p_channel.id][channel.id] = webhook
      channel.send_message("✅ **#{p_channel.server.name} ##{p_channel.name}** と接続されました")
      p_channel.send_message("✅ **#{channel.server.name} ##{channel.name}** と接続されました")
    end
  end

  # ペアまたはキューの削除
  def remove_link(channel, p_channel_id)
    p_channel = get_p_channel(p_channel_id)
    p_webhook = @link_pairs[channel.id].delete(p_channel_id)

    # キューの削除
    if p_webhook.nil?
      webhook = @link_queues[channel.id].delete(p_channel_id)
      if webhook
        webhook.delete
        if p_channel
          channel.send_message("✅ **#{p_channel.server.name} ##{p_channel.name}** の接続待ちがキャンセルされました")
        else
          channel.send_message("✅ 接続待ちがキャンセルされました")
        end
      end
      return
    end

    # ペアの削除
    webhook = @link_pairs[p_channel_id].delete(channel.id)
    if webhook
      webhook.delete
      if p_channel
        channel.send_message("✅ **#{p_channel.server.name} ##{p_channel.name}** と切断されました")
      else
        channel.send_message("✅ 切断されました")
      end
    end
    
    p_webhook.delete
    if p_channel
      p_channel.send_message("✅ **#{channel.server.name} ##{channel.name}** と切断されました")
    end
  end

  # すべての接続を切断
  def remove_all_links(channel)
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      remove_link(channel, p_channel_id)
    end
  end

  # 接続確認
  def check_links(channel)
    webhook_ids = channel.webhooks.map { |webhook| webhook.id }
    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      webhook = @link_pairs[p_channel_id][channel.id]
      remove_link(channel, p_channel_id) unless webhook_ids.include?(webhook.id)
    end
  end

  # メッセージ送信
  def send_content(event)
    channel = event.channel
    message = event.message

    unless @link_pairs[channel.id]
      resume_links(channel)
      return
    end

    @link_pairs[channel.id].each do |p_channel_id, p_webhook|
      client = Discordrb::Webhooks::Client.new(id: p_webhook.id, token: p_webhook.token)
      client.execute do |builder|
        builder.avatar_url = message.author.avatar_url
        builder.username = message.author.display_name
        builder.content = message.content
      end
    end
  end

  # 接続再構築
  def resume_links(channel)
  end

  # 相手チャンネルを取得
  def get_p_channel(p_channel_id, channel = nil)
    begin
      p_channel = @bot.channel(p_channel_id)
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠ **指定されたチャンネルにBOTが導入されていません**") if channel
      return nil
    end

    if p_channel.nil?
      channel.send_message("⚠ **指定されたチャンネルは存在しません**") if channel
      return nil
    end

    p_channel
  end

  # Webhookの取得または作成
  def get_webhook(channel, p_channel)
    # 既存のWebhookを取得
    begin
      webhooks = channel.webhooks.select do |webhook|
        webhook.name =~ /^Telehook<(\d+)>$/
        $1.to_i == p_channel.id
      end
    rescue Discordrb::Errors::NoPermission
      channel.send_message("⚠ BOTに **ウェブフックの管理** 権限が必要です")
      return nil
    end

    # Webhookを作成
    if webhooks.empty?
      begin
        webhook = channel.create_webhook("Telehook<#{p_channel.id}>")
      rescue Discordrb::Errors::NoPermission
        channel.send_message("⚠ BOTに **ウェブフックの管理** 権限が必要です")
        return nil
      end
      return webhook
    end

    webhooks.first
  end
end
