Below this request's text (these instructions, the body and any notes) comes a file list, which
precedes the diffs it indexes: "Files in this change (<n>):", then one line per file or part, as `<mark> +<added> -<removed>  <label>`. The mark says where that file's patch is:
- shown: in this request. Review it.
- earlier: shown in an earlier round of this review. Judge the change as it now stands, with
  what you saw then.
- elsewhere: shown in another slice of this review, which has its own turn. You may open the
  file.
- listed: a plan covered by its approved plan review. Its patch is not shown, except any
  later change.

With several targets, a path carries its target's label (`<repo-path>:`). A file split into
parts has one line per part, labelled `<path>#<i>/<n>`.

List in `reviewed_files` every file or part label marked shown that you reviewed. Do not list a file you did not read.
