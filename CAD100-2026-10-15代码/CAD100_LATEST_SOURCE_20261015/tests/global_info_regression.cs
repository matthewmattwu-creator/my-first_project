using System;
using System.Collections.Generic;
using System.Data;
using System.IO;
using System.Reflection;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
class GlobalInfoRegression
{
    static BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
    static void Check(bool condition, string label) { if(!condition) throw new Exception(label); Console.WriteLine("PASS " + label); }
    static void Invoke(object instance, string name, params object[] args) { instance.GetType().GetMethod(name,flags).Invoke(instance,args); }
    [STAThread] static int Main(string[] args)
    {
        Window window=null;
        try
        {
            var assembly=Assembly.LoadFrom(Path.GetFullPath(args[0]));
            window=(Window)Activator.CreateInstance(assembly.GetType("Drawing100WpfPreview.MainWindow"));
            var type=window.GetType();
            var editors=(Dictionary<string,TextBox>)type.GetField("projectEditors",flags).GetValue(window);
            var core=type.GetField("core",flags).GetValue(window);
            var coreType=core.GetType();
            var values=new Dictionary<string,string> {
                {"project","保留项目"},{"number","P-001"},{"subitem","测试子项"},
                {"owner","测试建设单位"},{"revision","A"},{"date","2026-10-13"},
                {"type","施工图"},{"scale_unit","1/100 / mm"}};
            foreach(var item in values) editors[item.Key].Text=item.Value;
            Check((string)coreType.GetProperty("ShellProject").GetValue(core,null)=="保留项目", "typing reaches core without processing");
            var table=(DataTable)coreType.GetProperty("ShellTable").GetValue(core,null);
            var row=table.NewRow(); row["drawing"]="test.dwg"; row["图号"]="TEST-01"; row["图名"]="测试"; row["设计项目名"]="逐图独立值";
            table.Rows.Add(row);
            coreType.GetMethod("ShellSetPersonnelName").Invoke(core,new object[]{"N设计_T5_H3","保留人员"});
            Invoke(window,"SyncFromCore");
            Invoke(window,"ClearProjectInformation");
            foreach(var item in editors) Check(item.Value.Text=="", "clear editor "+item.Key);
            Check((string)row["设计项目名"]=="逐图独立值", "clear does not erase per-drawing data");
            Check((string)coreType.GetMethod("ShellPersonnelName").Invoke(core,new object[]{"N设计_T5_H3"})=="保留人员", "clear preserves personnel");
            foreach(var item in values) editors[item.Key].Text=item.Value;
            string fixture=Path.GetFullPath(args[1]); Directory.CreateDirectory(fixture);
            // Same reset routine used by ShellScanDirectoryAsync, without CAD.
            Invoke(core,"LoadBatchDirectory",fixture,true);
            Invoke(window,"SetSelectedInputDirectory",fixture);
            Invoke(window,"SyncFromCore");
            foreach(var item in values) Check(editors[item.Key].Text==item.Value, "switch retains "+item.Key);
            Check(table.Rows.Count==0,"switch resets only the old scan table");
            Check((string)coreType.GetProperty("ShellScale").GetValue(core,null)=="1/100", "fraction scale with unit preserved");
            editors["scale_unit"].Text="1/100"; Invoke(window,"SyncFromCore");
            Check(editors["scale_unit"].Text=="1/100","fraction without unit survives refresh");
            Invoke(window,"ClearProjectInformation"); Invoke(window,"SyncFromCore");
            foreach(var item in editors) Check(item.Value.Text=="","clear stays empty after refresh "+item.Key);
            var personnel=(Dictionary<string,TextBox>)type.GetField("personnelEditors",flags).GetValue(window);
            Check(personnel.Count==10,"ten personnel editors are available");
            foreach(var item in personnel) item.Value.Text="姓名-"+item.Key;
            Invoke(core,"LoadBatchDirectory",fixture,true);
            Invoke(window,"SetSelectedInputDirectory",fixture); Invoke(window,"SyncFromCore");
            foreach(var item in personnel) Check(item.Value.Text=="姓名-"+item.Key,"switch retains personnel "+item.Key);
            editors["project"].Text="保留统一项目";
            string signature=Path.Combine(Path.GetDirectoryName(Path.GetFullPath(args[0])),"engine","assets","NEW_TITLE.dwg");
            coreType.GetMethod("ShellSetSignaturePath").Invoke(core,new object[]{"签字图块_设计",signature});
            var personnelRow=table.NewRow(); personnelRow["drawing"]="test.dwg";
            personnelRow["图名"]="测试"; personnelRow["图号"]="TEST-01";
            personnelRow["N设计_T5_H3"]="逐图人员原值"; table.Rows.Add(personnelRow);
            Invoke(window,"ClearPersonnelInformation"); Invoke(window,"SyncFromCore");
            foreach(var item in personnel) Check(item.Value.Text=="","clear personnel "+item.Key);
            Check(editors["project"].Text=="保留统一项目","personnel clear preserves global information");
            Check((string)personnelRow["N设计_T5_H3"]=="逐图人员原值","personnel clear preserves per-drawing names");
            Check((string)coreType.GetMethod("ShellSignaturePath").Invoke(core,new object[]{"签字图块_设计"})==signature,"personnel clear preserves signature selection");
            var signatureBoxes=(System.Collections.IDictionary)coreType.GetField("personnelSignatureBoxes",flags).GetValue(core);
            var signatureBox=signatureBoxes["签字图块_设计"];
            signatureBox.GetType().GetProperty("Text").SetValue(signatureBox,string.Empty,null);
            table.Rows.Clear(); Invoke(window,"SyncFromCore");
            if(args.Length>2)
            {
                var content=(FrameworkElement)window.Content;
                content.Measure(new Size(1664,946));
                content.Arrange(new Rect(0,0,1664,946)); content.UpdateLayout();
                var bitmap=new RenderTargetBitmap(1664,946,96,96,PixelFormats.Pbgra32);
                bitmap.Render(content);
                var encoder=new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using(var file=File.Create(args[2])) encoder.Save(file);
            }
            Console.WriteLine("ALL CHECKS PASSED; no CAD processing or drawing writes were performed.");
            return 0;
        }
        catch(Exception ex) { Console.WriteLine(ex.ToString()); return 1; }
        finally { if(window!=null) window.Close(); }
    }
}
