using System.Diagnostics;
using System.Drawing.Drawing2D;

namespace NRadioRecorder.Windows;

internal sealed class MainForm : Form
{
    private readonly ComboBox processPicker = new();
    private readonly ComboBox microphonePicker = new();
    private readonly ComboBox formatPicker = new();
    private readonly CheckBox applicationEnabled = new() { Text = "录制 App 音频", Checked = true, AutoSize = true };
    private readonly CheckBox microphoneEnabled = new() { Text = "录制麦克风", AutoSize = true };
    private readonly TextBox outputDirectory = new();
    private readonly Button refreshButton = new();
    private readonly Button chooseFolderButton = new();
    private readonly Button recordButton = new();
    private readonly Button revealButton = new();
    private readonly Label timerLabel = new();
    private readonly Label stateLabel = new();
    private readonly Label statusLabel = new();
    private readonly System.Windows.Forms.Timer elapsedTimer = new() { Interval = 1000 };
    private readonly RecordingService recordingService = new();
    private DateTimeOffset startedAt;
    private string? lastRecordingPath;
    private bool busy;

    public MainForm()
    {
        Text = "NRadio 直播录音";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(700, 700);
        ClientSize = new Size(760, 760);
        BackColor = Color.FromArgb(17, 20, 32);
        ForeColor = Color.White;
        Font = new Font("Microsoft YaHei UI", 10F);
        AutoScaleMode = AutoScaleMode.Dpi;

        BuildInterface();
        Load += (_, _) => RefreshSources();
        recordingService.Failed += _ =>
        {
            if (!IsDisposed && IsHandleCreated) BeginInvoke(async () =>
            {
                if (recordingService.IsRecording && recordingService.HasFailure && !busy)
                    await StopRecordingAsync();
            });
        };
        FormClosing += OnFormClosing;
        elapsedTimer.Tick += (_, _) => UpdateElapsedTime();
    }

    private void BuildInterface()
    {
        var root = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(34, 28, 34, 28),
            ColumnCount = 1,
            RowCount = 11,
            BackColor = Color.Transparent
        };
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 58));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 190));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);

        var titlePanel = new Panel { Dock = DockStyle.Fill };
        titlePanel.Controls.Add(new Label
        {
            Text = "NRadio 直播录音",
            Font = new Font(Font.FontFamily, 24F, FontStyle.Bold),
            ForeColor = Color.White,
            AutoSize = true,
            Location = new Point(0, 0)
        });
        titlePanel.Controls.Add(new Label
        {
            Text = "App 音频 / 麦克风 / 两者混录 · WAV 或 MP3 · 不录视频",
            Font = new Font(Font.FontFamily, 9.5F),
            ForeColor = Color.FromArgb(165, 170, 188),
            AutoSize = true,
            Location = new Point(2, 45)
        });
        root.Controls.Add(titlePanel, 0, 0);

        applicationEnabled.Dock = DockStyle.Fill;
        applicationEnabled.CheckedChanged += (_, _) => UpdateSourceControls();
        root.Controls.Add(applicationEnabled, 0, 1);
        var sourceRow = TwoColumnRow(refreshButton, 106);
        ConfigurePicker(processPicker);
        sourceRow.Controls.Add(processPicker, 0, 0);
        refreshButton.Text = "↻  刷新";
        StyleSecondaryButton(refreshButton);
        refreshButton.Click += (_, _) => RefreshSources();
        root.Controls.Add(sourceRow, 0, 2);

        microphoneEnabled.Dock = DockStyle.Fill;
        microphoneEnabled.CheckedChanged += (_, _) => UpdateSourceControls();
        root.Controls.Add(microphoneEnabled, 0, 3);
        ConfigurePicker(microphonePicker);
        root.Controls.Add(microphonePicker, 0, 4);

        root.Controls.Add(SectionLabel("输出格式"), 0, 5);
        ConfigurePicker(formatPicker);
        formatPicker.DataSource = new[] { "WAV · 无损音频", "MP3 · 小体积" };
        root.Controls.Add(formatPicker, 0, 6);

        root.Controls.Add(SectionLabel("保存位置"), 0, 7);
        var destinationRow = TwoColumnRow(chooseFolderButton, 106);
        ConfigureTextBox(outputDirectory);
        outputDirectory.Text = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            "NRadio Live Recordings");
        destinationRow.Controls.Add(outputDirectory, 0, 0);
        chooseFolderButton.Text = "选择…";
        StyleSecondaryButton(chooseFolderButton);
        chooseFolderButton.Click += (_, _) => ChooseOutputFolder();
        root.Controls.Add(destinationRow, 0, 8);

        var recordingCard = new RoundedPanel
        {
            Dock = DockStyle.Fill,
            Margin = new Padding(0, 14, 0, 10),
            Padding = new Padding(24),
            BackColor = Color.FromArgb(29, 32, 47)
        };
        root.Controls.Add(recordingCard, 0, 9);

        var indicator = new Panel
        {
            BackColor = Color.FromArgb(112, 86, 236),
            Size = new Size(52, 52),
            Location = new Point(25, 42)
        };
        indicator.Region = new Region(new GraphicsPath(new[]
        {
            new Point(26, 0), new Point(52, 26), new Point(26, 52), new Point(0, 26)
        }, new byte[] { 0, 1, 1, 1 }));
        recordingCard.Controls.Add(indicator);

        stateLabel.Text = "准备录制";
        stateLabel.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
        stateLabel.AutoSize = true;
        stateLabel.Location = new Point(98, 29);
        recordingCard.Controls.Add(stateLabel);

        timerLabel.Text = "00:00:00";
        timerLabel.Font = new Font("Consolas", 28F, FontStyle.Regular);
        timerLabel.AutoSize = true;
        timerLabel.Location = new Point(94, 52);
        recordingCard.Controls.Add(timerLabel);

        var formatLabel = new Label
        {
            Text = "纯音频 · 48 kHz · 双声道",
            ForeColor = Color.FromArgb(155, 160, 178),
            AutoSize = true,
            Location = new Point(99, 105)
        };
        recordingCard.Controls.Add(formatLabel);

        recordButton.Text = "开始录音";
        recordButton.Size = new Size(132, 46);
        recordButton.Anchor = AnchorStyles.Top | AnchorStyles.Right;
        recordButton.Location = new Point(recordingCard.Width - 165, 54);
        recordButton.BackColor = Color.FromArgb(112, 86, 236);
        recordButton.ForeColor = Color.White;
        recordButton.FlatStyle = FlatStyle.Flat;
        recordButton.FlatAppearance.BorderSize = 0;
        recordButton.Font = new Font(Font.FontFamily, 10F, FontStyle.Bold);
        recordButton.Click += async (_, _) => await ToggleRecordingAsync();
        recordingCard.Controls.Add(recordButton);
        recordingCard.Resize += (_, _) => recordButton.Left = recordingCard.ClientSize.Width - recordButton.Width - 25;

        var footer = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 2,
            Padding = new Padding(0, 8, 0, 0)
        };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        statusLabel.Text = "请选择正在播放直播的软件。";
        statusLabel.ForeColor = Color.FromArgb(165, 170, 188);
        statusLabel.AutoEllipsis = true;
        statusLabel.Dock = DockStyle.Fill;
        footer.Controls.Add(statusLabel, 0, 0);
        revealButton.Text = "打开保存位置";
        revealButton.AutoSize = true;
        revealButton.Visible = false;
        StyleLinkButton(revealButton);
        revealButton.Click += (_, _) => RevealLastRecording();
        footer.Controls.Add(revealButton, 1, 0);
        root.Controls.Add(footer, 0, 10);
    }

    private void RefreshSources()
    {
        RefreshApplications();
        var previousId = (microphonePicker.SelectedItem as MicrophoneItem)?.Id;
        try
        {
            var microphones = MicrophoneItem.GetAvailable();
            microphonePicker.DataSource = microphones;
            microphonePicker.DisplayMember = nameof(MicrophoneItem.Name);
            var previous = microphones.FirstOrDefault(item => item.Id == previousId);
            if (previous is not null) microphonePicker.SelectedItem = previous;
        }
        catch (Exception ex) { statusLabel.Text = $"无法读取麦克风：{ex.Message}。仍可仅录 App 音频。"; }
        UpdateSourceControls();
    }

    private void UpdateSourceControls()
    {
        var editable = !busy && !recordingService.IsRecording;
        applicationEnabled.Enabled = microphoneEnabled.Enabled = formatPicker.Enabled = editable;
        processPicker.Enabled = editable && applicationEnabled.Checked;
        microphonePicker.Enabled = editable && microphoneEnabled.Checked;
        refreshButton.Enabled = outputDirectory.Enabled = chooseFolderButton.Enabled = editable;
        recordButton.Enabled = !busy && (recordingService.IsRecording ||
            (applicationEnabled.Checked || microphoneEnabled.Checked));
    }

    private void RefreshApplications()
    {
        var previousId = (processPicker.SelectedItem as ProcessItem)?.Id;
        var applications = ProcessItem.GetVisibleApplications();
        processPicker.DataSource = applications;
        processPicker.DisplayMember = nameof(ProcessItem.DisplayName);

        if (previousId is not null)
        {
            var previous = applications.FirstOrDefault(item => item.Id == previousId);
            if (previous is not null) processPicker.SelectedItem = previous;
        }

        statusLabel.Text = applications.Count == 0
            ? "没有发现可录音的软件，请先打开直播软件后再刷新。"
            : "请选择正在播放直播的软件。";
    }

    private async Task ToggleRecordingAsync()
    {
        if (busy) return;
        if (recordingService.IsRecording)
        {
            await StopRecordingAsync();
        }
        else
        {
            await StartRecordingAsync();
        }
    }

    private async Task StartRecordingAsync()
    {
        var process = applicationEnabled.Checked ? processPicker.SelectedItem as ProcessItem : null;
        var microphone = microphoneEnabled.Checked ? microphonePicker.SelectedItem as MicrophoneItem : null;
        if (!applicationEnabled.Checked && !microphoneEnabled.Checked)
        {
            ShowError("请至少开启 App 音频或麦克风中的一项。");
            return;
        }
        if (applicationEnabled.Checked && process is null)
        {
            ShowError("请先选择一个录音软件。");
            return;
        }
        if (microphoneEnabled.Checked && microphone is null)
        {
            ShowError("请先选择一个可用麦克风。");
            return;
        }

        if (string.IsNullOrWhiteSpace(outputDirectory.Text))
        {
            ShowError("请选择录音保存位置。");
            return;
        }

        SetBusy(true);
        statusLabel.Text = "正在准备所选音频源…";

        try
        {
            var sourceName = string.Join(" + ", new[] { process?.Name, microphone?.Name }.Where(name => name is not null));
            var safeName = string.Concat(sourceName.Select(ch => Path.GetInvalidFileNameChars().Contains(ch) ? '-' : ch));
            var format = formatPicker.SelectedIndex == 1 ? RecordingFormat.Mp3 : RecordingFormat.Wav;
            var stem = $"录音_{safeName}_{DateTime.Now:yyyy-MM-dd_HH-mm-ss}";
            var extension = format == RecordingFormat.Wav ? "wav" : "mp3";
            var suffix = 1;
            do
            {
                var fileName = $"{stem}{(suffix == 1 ? "" : "-" + suffix)}.{extension}";
                lastRecordingPath = Path.Combine(Path.GetFullPath(outputDirectory.Text.Trim()), fileName);
                suffix++;
            } while (File.Exists(lastRecordingPath) || File.Exists(lastRecordingPath + ".recording.wav"));
            revealButton.Visible = false;
            await recordingService.StartAsync(process is null ? null : (uint)process.Id, microphone?.Id, lastRecordingPath, format);

            startedAt = DateTimeOffset.Now;
            timerLabel.Text = "00:00:00";
            elapsedTimer.Start();
            stateLabel.Text = "正在录制";
            recordButton.Text = "停止并保存";
            recordButton.BackColor = Color.FromArgb(220, 62, 77);
            statusLabel.Text = $"正在录制：{sourceName} · {extension.ToUpperInvariant()}";
        }
        catch (Exception ex)
        {
            lastRecordingPath = recordingService.RecoverablePath;
            revealButton.Visible = lastRecordingPath is not null;
            ShowError($"无法开始录音：{ex.Message}");
        }
        finally
        {
            SetBusy(false);
            if (recordingService.IsRecording && recordingService.HasFailure) await StopRecordingAsync();
        }
    }

    private async Task StopRecordingAsync()
    {
        if (busy || !recordingService.IsRecording) return;
        elapsedTimer.Stop();
        SetBusy(true);
        statusLabel.Text = formatPicker.SelectedIndex == 1 ? "正在编码并保存 MP3，请稍候…" : "正在保存 WAV…";

        try
        {
            lastRecordingPath = await recordingService.StopAsync();
            statusLabel.Text = "录音已保存，可以直接用于转写和知识库总结。";
            revealButton.Visible = true;
        }
        catch (Exception ex)
        {
            lastRecordingPath = recordingService.RecoverablePath;
            revealButton.Visible = lastRecordingPath is not null;
            ShowError($"停止录音时出现问题：{ex.Message}");
        }
        finally
        {
            stateLabel.Text = "准备录制";
            recordButton.Text = "开始录音";
            recordButton.BackColor = Color.FromArgb(112, 86, 236);
            SetBusy(false);
        }
    }

    private void ChooseOutputFolder()
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "选择录音保存位置",
            UseDescriptionForTitle = true,
            InitialDirectory = outputDirectory.Text,
            ShowNewFolderButton = true
        };

        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            outputDirectory.Text = dialog.SelectedPath;
        }
    }

    private void RevealLastRecording()
    {
        if (lastRecordingPath is null) return;
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{lastRecordingPath}\"")
        {
            UseShellExecute = true
        });
    }

    private void UpdateElapsedTime()
    {
        var elapsed = DateTimeOffset.Now - startedAt;
        timerLabel.Text = $"{(int)elapsed.TotalHours:00}:{elapsed.Minutes:00}:{elapsed.Seconds:00}";
    }

    private void SetBusy(bool busy)
    {
        this.busy = busy;
        UseWaitCursor = busy;
        UpdateSourceControls();
    }

    private void ShowError(string message)
    {
        statusLabel.Text = message;
        MessageBox.Show(this, message, "NRadio 直播录音", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private async void OnFormClosing(object? sender, FormClosingEventArgs e)
    {
        // Do not dispose this form while a start or save continuation is pending.
        if (busy)
        {
            e.Cancel = true;
            return;
        }
        if (!recordingService.IsRecording) return;

        e.Cancel = true;
        Enabled = false;
        try
        {
            await StopRecordingAsync();
            await recordingService.DisposeAsync();
        }
        finally
        {
            FormClosing -= OnFormClosing;
            Close();
        }
    }

    private static Label SectionLabel(string text) => new()
    {
        Text = text,
        Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold),
        ForeColor = Color.FromArgb(224, 226, 235),
        Dock = DockStyle.Fill,
        TextAlign = ContentAlignment.BottomLeft
    };

    private static TableLayoutPanel TwoColumnRow(Control button, int buttonWidth)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, Margin = Padding.Empty };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, buttonWidth));
        row.Controls.Add(button, 1, 0);
        return row;
    }

    private static void ConfigurePicker(ComboBox comboBox)
    {
        comboBox.Dock = DockStyle.Fill;
        comboBox.DropDownStyle = ComboBoxStyle.DropDownList;
        comboBox.BackColor = Color.FromArgb(30, 34, 49);
        comboBox.ForeColor = Color.White;
        comboBox.FlatStyle = FlatStyle.Flat;
        comboBox.Margin = new Padding(0, 8, 12, 8);
    }

    private static void ConfigureTextBox(TextBox textBox)
    {
        textBox.Dock = DockStyle.Fill;
        textBox.BackColor = Color.FromArgb(30, 34, 49);
        textBox.ForeColor = Color.White;
        textBox.BorderStyle = BorderStyle.FixedSingle;
        textBox.Margin = new Padding(0, 8, 12, 8);
    }

    private static void StyleSecondaryButton(Button button)
    {
        button.Dock = DockStyle.Fill;
        button.Margin = new Padding(0, 8, 0, 8);
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderColor = Color.FromArgb(70, 74, 92);
        button.BackColor = Color.FromArgb(34, 38, 54);
        button.ForeColor = Color.White;
    }

    private static void StyleLinkButton(Button button)
    {
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0;
        button.BackColor = Color.Transparent;
        button.ForeColor = Color.FromArgb(151, 130, 255);
    }
}

internal sealed class RoundedPanel : Panel
{
    protected override void OnResize(EventArgs eventargs)
    {
        base.OnResize(eventargs);
        using var path = RoundedRectangle(ClientRectangle, 16);
        Region = new Region(path);
    }

    private static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
    {
        var diameter = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(bounds.Left, bounds.Top, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Top, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.Left, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        return path;
    }
}
