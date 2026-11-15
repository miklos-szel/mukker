using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using Mukker.Core.Snippets;
using Mukker.Core.Storage;

namespace Mukker.App.Snippets;

/// <summary>Small modal helpers shared by the popup and the manager.</summary>
internal static class Ui
{
    public static TextBlock Label(string text, double top = 0) => new() { Text = text, Margin = new Thickness(0, top, 0, 4), FontWeight = FontWeights.SemiBold };

    /// <summary>A one-field text prompt. Returns null when cancelled.</summary>
    public static string? Ask(Window? owner, string title, string label, string initial)
    {
        var w = new Window
        {
            Title = title, Owner = owner, SizeToContent = SizeToContent.Height, Width = 380, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen,
            ShowInTaskbar = false, Topmost = owner?.Topmost ?? false,
        };
        var box = new TextBox { Text = initial };
        string? result = null;
        var ok = new Button { Content = "OK", IsDefault = true, Style = (Style)Application.Current.FindResource("AccentButton"), MinWidth = 80, Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80 };
        ok.Click += (_, _) => { result = box.Text; w.DialogResult = true; };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(Label(label));
        root.Children.Add(box);
        root.Children.Add(buttons);
        w.Content = root;
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        return w.ShowDialog() == true ? result : null;
    }
}

/// <summary>Names a clip that is being saved as a snippet and picks (or creates) its collection.</summary>
internal sealed class SnippetNamePrompt : Window
{
    private const string NewCollection = "New Collection…";

    public SnippetNamePrompt(AppHost host, string text, long? preselectCollection)
    {
        Title = "Save as Snippet";
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ShowInTaskbar = false;
        Topmost = true;

        var collections = host.Snippets.Collections();
        var combo = new ComboBox();
        foreach (var c in collections) combo.Items.Add(c.Name);
        combo.Items.Add(NewCollection);
        var idx = preselectCollection is long id ? collections.FindIndex(c => c.Id == id) : (collections.Count > 0 ? 0 : -1);
        combo.SelectedIndex = idx >= 0 ? idx : combo.Items.Count - 1;

        var newName = new TextBox { Text = "Snippets" };
        var newLabel = Ui.Label("New collection name", 10);
        void SyncNew()
        {
            var isNew = (string?)combo.SelectedItem == NewCollection;
            newName.Visibility = newLabel.Visibility = isNew ? Visibility.Visible : Visibility.Collapsed;
        }
        combo.SelectionChanged += (_, _) => SyncNew();
        SyncNew();

        var defaultName = SnippetNaming.DefaultName(text);
        var name = new TextBox { Text = defaultName };
        var ok = new Button { Content = "Save", IsDefault = true, Style = (Style)Application.Current.FindResource("AccentButton"), MinWidth = 80, Margin = new Thickness(8, 0, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80 };
        ok.Click += (_, _) =>
        {
            try
            {
                long collectionId;
                if ((string?)combo.SelectedItem == NewCollection)
                    collectionId = host.Snippets.CreateCollection(SnippetNaming.Normalize(newName.Text, "Snippets")).Id;
                else
                    collectionId = collections[combo.SelectedIndex].Id;
                host.Snippets.AddSnippet(collectionId, SnippetNaming.Normalize(name.Text, defaultName), text);
                DialogResult = true;
            }
            catch (Exception e)
            {
                MessageBox.Show(this, e.Message, "Could not save the snippet", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
        };
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);

        var root = new StackPanel { Margin = new Thickness(16) };
        root.Children.Add(Ui.Label("Collection"));
        root.Children.Add(combo);
        root.Children.Add(newLabel);
        root.Children.Add(newName);
        root.Children.Add(Ui.Label("Snippet name", 10));
        root.Children.Add(name);
        root.Children.Add(new TextBlock { Text = $"Up to {SnippetNaming.MaxLength} characters.", Style = (Style)Application.Current.FindResource("Caption"), Margin = new Thickness(0, 4, 0, 0) });
        root.Children.Add(buttons);
        Content = root;
        Loaded += (_, _) => { name.Focus(); name.SelectAll(); };
    }
}

/// <summary>Collections on the left, their snippets in the middle, the selected snippet's editor on the right.</summary>
internal sealed class SnippetsManagerWindow : Window
{
    private readonly AppHost _host;
    private readonly ListBox _collections = new() { BorderThickness = new Thickness(0), DisplayMemberPath = "Name" };
    private readonly ListBox _snippets = new() { BorderThickness = new Thickness(0), DisplayMemberPath = "Name" };
    private readonly TextBox _name = new();
    private readonly TextBox _keyword = new();
    private readonly TextBox _content = new()
    {
        AcceptsReturn = true, AcceptsTab = true, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalContentAlignment = VerticalAlignment.Top, FontFamily = new FontFamily("Cascadia Mono, Consolas"),
    };
    private readonly Button _save = new() { Content = "Save", MinWidth = 80 };
    private readonly Grid _editor = new();
    private bool _loading;

    public SnippetsManagerWindow(AppHost host)
    {
        _host = host;
        Title = "Mukker — Snippets";
        Width = 980;
        Height = 620;
        MinWidth = 720;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = (Brush)FindResource("Surface");
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Mukker;component/Assets/mukker.ico"));
        _save.Style = (Style)FindResource("AccentButton");

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(230) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(260) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        grid.Children.Add(Column("Collections", _collections, 0,
            ("", "New collection", NewCollection), ("", "Rename", RenameCollection), ("", "Delete collection", DeleteCollection),
            ("", "Import…", Import), ("", "Export…", Export)));
        grid.Children.Add(Divider(1));
        grid.Children.Add(Column("Snippets", _snippets, 2,
            ("", "New snippet", NewSnippet), ("", "Delete snippet", DeleteSnippet)));
        grid.Children.Add(Divider(3));

        _editor.Margin = new Thickness(16, 12, 16, 16);
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _editor.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _editor.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        AddRow(Ui.Label("Name"), 0);
        AddRow(_name, 1);
        AddRow(Ui.Label("Keyword (search only)", 10), 2);
        AddRow(_keyword, 3);
        AddRow(Ui.Label("Content", 10), 4);
        AddRow(_content, 5);
        var bar = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 10, 0, 0) };
        bar.Children.Add(new TextBlock { Text = "Ctrl+S", Style = (Style)FindResource("Caption"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 10, 0) });
        bar.Children.Add(_save);
        AddRow(bar, 6);
        Grid.SetColumn(_editor, 4);
        grid.Children.Add(_editor);
        Content = grid;

        _collections.SelectionChanged += (_, _) => LoadSnippets();
        _snippets.SelectionChanged += (_, _) => LoadEditor();
        _save.Click += (_, _) => SaveSnippet();
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == Key.S && Keyboard.Modifiers == ModifierKeys.Control) { SaveSnippet(); e.Handled = true; }
            if (e.Key == Key.W && Keyboard.Modifiers == ModifierKeys.Control) { Close(); e.Handled = true; }
        };
        LoadCollections();
    }

    private void AddRow(UIElement e, int row)
    {
        Grid.SetRow(e, row);
        _editor.Children.Add(e);
    }

    private Border Divider(int col)
    {
        var b = new Border { Background = (Brush)FindResource("Hairline") };
        Grid.SetColumn(b, col);
        return b;
    }

    private DockPanel Column(string title, ListBox list, int col, params (string Glyph, string Tip, Action Act)[] buttons)
    {
        var dock = new DockPanel { Background = (Brush)FindResource("SurfaceAlt") };
        var header = new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new Thickness(12, 12, 12, 6), Foreground = (Brush)FindResource("InkSoft") };
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(6) };
        foreach (var (glyph, tip, act) in buttons)
        {
            var b = new Button { Content = glyph, ToolTip = tip, Style = (Style)FindResource("IconButton") };
            b.Click += (_, _) => act();
            bar.Children.Add(b);
        }
        DockPanel.SetDock(bar, Dock.Bottom);
        dock.Children.Add(bar);
        list.Background = Brushes.Transparent;
        list.Margin = new Thickness(4, 0, 4, 0);
        dock.Children.Add(list);
        Grid.SetColumn(dock, col);
        return dock;
    }

    private SnippetCollection? SelectedCollection => _collections.SelectedItem as SnippetCollection;
    private Snippet? SelectedSnippet => _snippets.SelectedItem as Snippet;

    private void LoadCollections(long? select = null)
    {
        var keep = select ?? SelectedCollection?.Id;
        var list = _host.Snippets.Collections();
        _collections.ItemsSource = list;
        _collections.SelectedItem = list.FirstOrDefault(c => c.Id == keep) ?? list.FirstOrDefault();
        LoadSnippets();
    }

    private void LoadSnippets(long? select = null)
    {
        var keep = select ?? SelectedSnippet?.Id;
        var list = SelectedCollection is { } c ? _host.Snippets.Snippets(c.Id) : new();
        _snippets.ItemsSource = list;
        _snippets.SelectedItem = list.FirstOrDefault(s => s.Id == keep) ?? list.FirstOrDefault();
        LoadEditor();
    }

    private void LoadEditor()
    {
        _loading = true;
        var s = SelectedSnippet;
        _editor.IsEnabled = s != null;
        _name.Text = s?.Name ?? "";
        _keyword.Text = s?.Keyword ?? "";
        _content.Text = s?.Content ?? "";
        _loading = false;
    }

    private void SaveSnippet()
    {
        if (_loading || SelectedSnippet is not { } s) return;
        s.Name = SnippetNaming.Normalize(_name.Text, s.Name);
        s.Keyword = string.IsNullOrWhiteSpace(_keyword.Text) ? null : _keyword.Text.Trim();
        s.Content = _content.Text;
        _host.Snippets.UpdateSnippet(s);
        LoadSnippets(s.Id);
    }

    private void NewCollection()
    {
        var name = Ui.Ask(this, "New Collection", "Collection name", "Snippets");
        if (name == null) return;
        var c = _host.Snippets.CreateCollection(SnippetNaming.Normalize(name, "Snippets"));
        LoadCollections(c.Id);
    }

    private void RenameCollection()
    {
        if (SelectedCollection is not { } c) return;
        var name = Ui.Ask(this, "Rename Collection", "Collection name", c.Name);
        if (name == null) return;
        _host.Snippets.RenameCollection(c.Id, SnippetNaming.Normalize(name, c.Name));
        LoadCollections(c.Id);
    }

    private void DeleteCollection()
    {
        if (SelectedCollection is not { } c) return;
        var n = _host.Snippets.Snippets(c.Id).Count;
        if (MessageBox.Show(this, $"Delete \"{c.Name}\" and its {n} snippet(s)?", "Delete Collection", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        _host.Snippets.DeleteCollection(c.Id);
        LoadCollections();
    }

    private void NewSnippet()
    {
        if (SelectedCollection is not { } c)
        {
            NewCollection();
            if (SelectedCollection is not { } created) return;
            c = created;
        }
        var s = _host.Snippets.AddSnippet(c.Id, "New Snippet", "");
        LoadSnippets(s.Id);
        _name.Focus();
        _name.SelectAll();
    }

    private void DeleteSnippet()
    {
        if (SelectedSnippet is not { } s) return;
        if (MessageBox.Show(this, $"Delete \"{s.Name}\"?", "Delete Snippet", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        _host.Snippets.DeleteSnippet(s.Id);
        LoadSnippets();
    }

    private void Import()
    {
        var dlg = new OpenFileDialog { Filter = "Mukker snippets (*.json;*.mukker)|*.json;*.mukker|All files (*.*)|*.*", Title = "Import Snippets" };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            var n = MukkerSnippetsJson.ImportFile(dlg.FileName, _host.Snippets);
            LoadCollections();
            MessageBox.Show(this, $"Imported {n} snippet(s).", "Import Snippets", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception e)
        {
            MessageBox.Show(this, e.Message, "Could not import", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void Export()
    {
        var all = MessageBox.Show(this, "Export all collections?\n\nYes: every collection\nNo: only the selected collection",
            "Export Snippets", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (all == MessageBoxResult.Cancel) return;
        if (all == MessageBoxResult.No && SelectedCollection == null) return;
        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            FileName = all == MessageBoxResult.Yes ? "mukker-snippets.json" : $"{SafeFileName(SelectedCollection!.Name)}.json",
            Title = "Export Snippets",
        };
        if (dlg.ShowDialog(this) != true) return;
        try
        {
            var ids = all == MessageBoxResult.Yes ? null : new[] { SelectedCollection!.Id };
            File.WriteAllText(dlg.FileName, MukkerSnippetsJson.Export(_host.Snippets, ids, DateTime.UtcNow));
        }
        catch (Exception e)
        {
            MessageBox.Show(this, e.Message, "Could not export", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string SafeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var s = new string(name.Select(ch => invalid.Contains(ch) || ch is '\\' or '/' or ':' or '*' or '?' or '"' or '<' or '>' or '|' ? '_' : ch).ToArray());
        return s.Length == 0 ? "collection" : s;
    }
}
