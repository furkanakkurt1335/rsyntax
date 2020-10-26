find_nodes <- function(tokens, tquery, block=NULL, use_index=TRUE, name=NA, fill=TRUE, melt=TRUE, root_dist=FALSE) {
  .MATCH_ID = NULL; .DROP = NULL; .ID = NULL ## declare data.table bindings
  tokens = as_tokenindex(tokens)  
  block = get_long_ids(block)
  
  #nodes_list = list()
  nodes = filter_tokens(tokens, lookup=tquery$lookup, .G_ID=tquery$g_id, .BLOCK=block, use_index=use_index)
  if (nrow(nodes) == 0) return(NULL)
  nodes = subset(nodes, select = c('doc_id','sentence','token_id'))

  any_nonfill_nested = any(sapply(tquery$nested, function(x) !methods::is(x, 'tQueryFill')))
  if (any_nonfill_nested) {
    nodes = find_nested(tokens, nodes, tquery, block, fill=FALSE, block_loop=F)
  } else {
    data.table::setnames(nodes, old = 'token_id', new='.ID')
    if (!is.na(tquery$label)) nodes[,(tquery$label) := .ID]
  } 
  if (is.null(nodes)) return(NULL)  
  if (nrow(nodes) == 0) return(NULL)

  ### possible solution for removing block within rec_search
  if (root_dist) nodes = get_root_dist(tokens, nodes)
  nodes = get_unique_patterns(nodes)
  
  #print(nodes)
  if (fill) nodes = add_fill(tokens, nodes, tquery, block=nodes)
  #print(nodes)
  
  nodes = create_unique_key(nodes, name)
  if (melt) {
    nodes = melt_nodes_list(nodes)
  }
  nodes[]
}

find_nested <- function(tokens, nodes, tquery, block, fill, block_loop) {
  .ID = NULL; .MATCH_ID = NULL
  nodes = rec_find(tokens, ids=nodes, ql=tquery$nested, block=block, fill=fill, block_loop=block_loop)
  
  
  if (nrow(nodes) == 0) return(NULL)
  nodes[, .ID := .MATCH_ID]
  data.table::setcolorder(nodes, c('.ID', setdiff(colnames(nodes), '.ID')))
  
  if (is.na(tquery$label)) {
    nodes[,.MATCH_ID := NULL]
  } else {
    data.table::setnames(nodes, '.MATCH_ID', tquery$label)
  }
  
  dropcols = grep('.DROP.*', colnames(nodes), value=TRUE)
  if (length(dropcols) > 0) nodes[, (dropcols) := NULL]
  
  unique(nodes)
}

add_fill <- function(tokens, nodes, tquery, block, level=1) {
  is_fill = sapply(tquery$nested, methods::is, 'tQueryFill')

  if (any(!is_fill)) {
    for (tq in tquery$nested[!is_fill]) {
      nodes = add_fill(tokens, nodes, tq, block, level+1)
    }
  } 
  

  if (any(is_fill)) {
    if (is.na(tquery$label)) {
      if (level == 1) match_id = '.ID' else return(nodes)
    } else match_id = tquery$label
    if (!match_id %in% colnames(nodes)) return(nodes)
    ids = subset(nodes, select = c('doc_id','sentence',match_id))
    ids = unique(stats::na.omit(ids))
    add = rec_find(tokens, ids, tquery$nested[is_fill], block = block, fill=TRUE, block_loop=T)
    
    if (grepl('#', tquery$label)) {
      label = gsub('#.*', '', tquery$label)
      label = paste0('^', label, '\\_')
      colnames(add) = gsub(label, tquery$label, colnames(add))
    }

    if (nrow(add) > 0) {
      setkeyv(nodes, c('doc_id','sentence',match_id))
      nodes = merge(nodes, add, by.x=c('doc_id','sentence',match_id), by.y=c('doc_id','sentence','.MATCH_ID'), all.x=TRUE, allow.cartesian=TRUE)
      dropcols = grep('.DROP.*', colnames(nodes), value=TRUE)
      if (length(dropcols) > 0) nodes[, (dropcols) := NULL]
    }
  }
  unique(nodes)
}

create_unique_key <- function(nodes, name){
  #if (ncol(nodes) > 3) {
  #  key = paste0(name, '(', nodes$.ID, ':', do.call(paste, args = c(nodes[,-(1:3)], sep='.')), ')')
  #} else {
  #  key = paste0(name, '(', nodes$.ID, ')')
  #}      
  id_col = setdiff(colnames(nodes), c('doc_id','sentence','.ID'))[1]
  #key = paste0(name, '#', nodes$doc_id, '.', nodes$sentence, '.', match(nodes$.ID, unique(nodes$.ID)))
  if (!is.na(name)) {
    key = paste0(name, '#', nodes$doc_id, '.', nodes$sentence, '.', nodes[[id_col]])
  } else {
    key = paste0(nodes$doc_id, '.', nodes$sentence, '.', nodes[[id_col]])
  }


  nodes$.ID = paste0(nodes$doc_id, '...', nodes$sentence, '...', nodes$.ID) ## quick fix for matching on 3 columns
  key = key[match(nodes$.ID, nodes$.ID)] ## give same id to nodes with same .ID
  #key = paste0(name, '#', 1:nrow(nodes))
  nodes$.ID = key
  return(nodes)
}

get_unique_patterns <- function(nodes) {
  ln = nodes
  ln$i = 1:nrow(ln)
  ln = data.table::melt(ln, id.vars=c('doc_id','sentence','.ID','i'))
  ln = ln[!is.na(ln$value),]
  data.table::setorderv(ln, c('doc_id','sentence','.ID','i'))

  ## rm patterns nested in other patterns
  ids = unique(ln[,c('doc_id','sentence','.ID')])
  nested_ids = ln[list(ids$doc_id, ids$sentence, ids$.ID), , on=c('doc_id','sentence','value')]
  nested_ids = nested_ids[nested_ids$.ID != nested_ids$value]
  nested_i = ln[list(nested_ids$doc_id, nested_ids$sentence, nested_ids$value), , on=c('doc_id','sentence','.ID'), which=T]
  rm_i = unique(ln$i[nested_i])

  suppressWarnings({
  if (length(nested_i) > 0) ln = ln[-nested_i,]   ## extremely weird warning from data.table that seems ignorable
  })

  ## rm duplicate i-value pairs
  rm_j = unique(ln$i[duplicated(ln[,c('i','value')])])
  if (length(rm_j > 0)) ln = ln[-ln[list(i=rm_j), on='i', which=T]]
  
  ## rm any other overlapping nodes between ids
  ln_m = merge(ln, ln[,c('doc_id','sentence','.ID','value')], by=c('doc_id','sentence','value'), allow.cartesian = T)
  rm_k = unique(ln_m$i[ln_m$.ID.x > ln_m$.ID.y])
  
  if (length(rm_i) > 0 || length(rm_j) > 0 || length(rm_k) > 0)
    nodes = nodes[-unique(c(rm_i, rm_j, rm_k)),]
  
  nodes
  
}  


get_root_dist <- function(tokens, nodes) {
  .ROOT_DIST = NULL
  
  tf = token_family(tokens, unique(data.table(doc_id=nodes$doc_id, sentence=nodes$sentence, token_id=nodes$.ID)), 
                    depth=Inf, level='parents', minimal=TRUE, show_level=TRUE, replace=TRUE)
  tf = data.table::setorderv(tf, cols = '.FILL_LEVEL', order = -1)
  tf = unique(tf, by=c('doc_id','sentence','.MATCH_ID'))
  data.table::setnames(tf, c('.FILL_LEVEL', '.MATCH_ID'), c('.ROOT_DIST', '.ID'))
  tf = subset(tf, select=c('doc_id','sentence','.ID','.ROOT_DIST'))
  nodes = merge(nodes, tf, by = c('doc_id','sentence','.ID'), all.x=TRUE)
  #nodes = nodes[list(tf$doc_id, tf$sentence, tf$.MATCH_ID), .ROOT_DIST := tf$.FILL_LEVEL, on=c('doc_id','sentence','.ID')]
  nodes[is.na(nodes$.ROOT_DIST), .ROOT_DIST := 0]
  nodes
}


